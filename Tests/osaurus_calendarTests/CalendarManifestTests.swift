import Foundation
import OsaurusPluginKit
import XCTest

@testable import osaurus_calendar

final class CalendarManifestTests: XCTestCase {

  // MARK: - Manifest Tests

  private func decodeManifest() throws -> [String: Any] {
    let data = try XCTUnwrap(
      calendarManifestJSON.data(using: .utf8), "Manifest should be UTF-8 encodable")
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any], "Manifest should be a JSON object")
  }

  func testManifestPluginId() throws {
    let manifest = try decodeManifest()
    XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.calendar")
  }

  func testManifestVersionMatchesRelease() throws {
    let manifest = try decodeManifest()
    XCTAssertEqual(manifest["version"] as? String, "2.0.0")
  }

  func testExactToolInventoryAndPermissionPolicies() throws {
    let manifest = try decodeManifest()
    let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(capabilities["tools"] as? [[String: Any]])

    XCTAssertEqual(
      tools.compactMap { $0["id"] as? String },
      ["list_calendars", "query_events", "create_event", "open_event"])
    XCTAssertEqual(
      Dictionary(
        uniqueKeysWithValues: tools.compactMap { tool -> (String, String)? in
          guard let id = tool["id"] as? String,
            let policy = tool["permission_policy"] as? String
          else { return nil }
          return (id, policy)
        }),
      [
        "list_calendars": "auto",
        "query_events": "auto",
        "create_event": "ask",
        "open_event": "ask",
      ])
  }

  func testExactStrictParameterContracts() throws {
    let manifest = try decodeManifest()
    let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
    let tools = try XCTUnwrap(capabilities["tools"] as? [[String: Any]])
    let toolsById = Dictionary(
      uniqueKeysWithValues: tools.compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })

    let expectedProperties: [String: Set<String>] = [
      "list_calendars": [],
      "query_events": ["query", "limit", "range_start", "range_end"],
      "create_event": [
        "title", "start_at", "end_at", "location", "notes", "is_all_day",
        "calendar_name", "account_name",
      ],
      "open_event": ["event_id"],
    ]
    let expectedRequired: [String: Set<String>] = [
      "list_calendars": [],
      "query_events": [],
      "create_event": ["title", "start_at", "end_at"],
      "open_event": ["event_id"],
    ]

    for id in expectedProperties.keys {
      let tool = try XCTUnwrap(toolsById[id])
      XCTAssertNil(tool["annotations"], "\(id) must not declare annotations")
      XCTAssertNil(tool["outputSchema"], "\(id) must not declare outputSchema")
      let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
      XCTAssertEqual(parameters["type"] as? String, "object")
      XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
      let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
      XCTAssertEqual(Set(properties.keys), expectedProperties[id])
      XCTAssertEqual(Set(parameters["required"] as? [String] ?? []), expectedRequired[id])
    }

    let queryParameters = try XCTUnwrap(
      toolsById["query_events"]?["parameters"] as? [String: Any])
    let queryProperties = try XCTUnwrap(
      queryParameters["properties"] as? [String: Any])
    let limit = try XCTUnwrap(queryProperties["limit"] as? [String: Any])
    XCTAssertEqual(limit["minimum"] as? Int, 1)
    XCTAssertEqual(limit["maximum"] as? Int, Validation.maxLimit)
    XCTAssertEqual(limit["default"] as? Int, Validation.defaultLimit)
    for field in ["range_start", "range_end"] {
      let schema = try XCTUnwrap(queryProperties[field] as? [String: Any])
      XCTAssertEqual(schema["format"] as? String, "date-time")
    }
  }

  func testSkillIsPackagedOutsideRuntimeManifest() throws {
    let manifest = try decodeManifest()
    let capabilities = try XCTUnwrap(manifest["capabilities"] as? [String: Any])
    XCTAssertNil(capabilities["skills"])

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let skill = try String(
      contentsOf: repositoryRoot.appendingPathComponent("SKILL.md"),
      encoding: .utf8)
    XCTAssertTrue(skill.hasPrefix("---\nname: osaurus-calendar\n"))
    XCTAssertTrue(
      skill.contains(
        "\ndescription: Use when the user asks to inspect calendars, find events, create an event, or open an event in macOS Calendar.\n"))
  }

  // MARK: - Envelope Tests

  func testEnvelopeFailureRoundTrip() throws {
    let json = Envelope.failure(.invalidArgs, "bad input")

    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(object["ok"] as? Bool, false)
    XCTAssertEqual(object["kind"] as? String, "invalid_args")
    XCTAssertEqual(object["message"] as? String, "bad input")
    XCTAssertEqual(object["retryable"] as? Bool, true)
  }

  func testEnvelopeDefaultRetryablePerKind() throws {
    func retryable(_ json: String) throws -> Bool {
      let data = try XCTUnwrap(json.data(using: .utf8))
      let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      return try XCTUnwrap(object["retryable"] as? Bool)
    }

    XCTAssertEqual(try retryable(Envelope.failure(.invalidArgs, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.executionError, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.timeout, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.userDenied, "x")), false)
    XCTAssertEqual(try retryable(Envelope.failure(.notFound, "x")), false)
    XCTAssertEqual(try retryable(Envelope.failure(.toolNotFound, "x")), false)
  }

  func testEnvelopeFailureRespectsExplicitRetryable() throws {
    let json = Envelope.failure(.executionError, "flaky", retryable: false)
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "execution_error")
    XCTAssertEqual(object["retryable"] as? Bool, false)
  }

  func testEnvelopeEscapesMessage() throws {
    let json = Envelope.failure(.executionError, "line1\nwith \"quote\" and \\ backslash\ttab")
    // Must remain parseable JSON despite special characters in the message.
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["message"] as? String, "line1\nwith \"quote\" and \\ backslash\ttab")
  }
}
