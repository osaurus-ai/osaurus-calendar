import Foundation
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

  func testManifestToolsHaveIdAndDescription() throws {
    let manifest = try decodeManifest()
    let capabilities = try XCTUnwrap(
      manifest["capabilities"] as? [String: Any], "Manifest should have capabilities")
    let tools = try XCTUnwrap(
      capabilities["tools"] as? [[String: Any]], "Capabilities should have a tools array")

    XCTAssertFalse(tools.isEmpty, "Manifest should declare at least one tool")

    for (index, tool) in tools.enumerated() {
      let id = tool["id"] as? String
      XCTAssertNotNil(id, "Tool at index \(index) must have an 'id'")
      XCTAssertFalse(
        (id ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Tool at index \(index) must have a non-empty 'id'")

      let description = tool["description"] as? String
      XCTAssertNotNil(description, "Tool '\(id ?? "?")' must have a 'description'")
      XCTAssertFalse(
        (description ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        "Tool '\(id ?? "?")' must have a non-empty 'description'")
    }
  }

  // MARK: - Envelope Tests

  func testEnvelopeFailureRoundTrip() throws {
    let json = Envelope.failure(.invalidArgs, "bad input")
    XCTAssertTrue(json.hasPrefix("{\"ok\":false"), "Failure must start with {\"ok\":false")

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
    XCTAssertEqual(try retryable(Envelope.failure(.unavailable, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.notFound, "x")), false)
  }

  func testEnvelopeFailureRespectsExplicitRetryable() throws {
    let json = Envelope.failure(.unavailable, "denied", retryable: false)
    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["kind"] as? String, "unavailable")
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
