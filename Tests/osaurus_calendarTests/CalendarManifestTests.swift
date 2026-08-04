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
    XCTAssertEqual(manifest["version"] as? String, "1.2.0")
  }

  // Per-tool id/description/parameters checks are now covered by
  // ManifestConformance in SDKConformanceTests.

  // MARK: - Envelope Tests

  func testEnvelopeFailureRoundTrip() throws {
    let json = Envelope.failure(.invalidArgs, "bad input")
    XCTAssertTrue(json.hasPrefix("{\"ok\":false"), "Failure must start with {\"ok\":false")

    let data = try XCTUnwrap(json.data(using: .utf8))
    let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    XCTAssertEqual(object["ok"] as? Bool, false)
    XCTAssertEqual(object["kind"] as? String, "invalid_args")
    XCTAssertEqual(object["message"] as? String, "bad input")
    XCTAssertEqual(object["retryable"] as? Bool, false)
  }

  func testEnvelopeDefaultRetryablePerKind() throws {
    func retryable(_ json: String) throws -> Bool {
      let data = try XCTUnwrap(json.data(using: .utf8))
      let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      return try XCTUnwrap(object["retryable"] as? Bool)
    }

    XCTAssertEqual(try retryable(Envelope.failure(.invalidArgs, "x")), false)
    XCTAssertEqual(try retryable(Envelope.failure(.executionError, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.timeout, "x")), true)
    XCTAssertEqual(try retryable(Envelope.failure(.permissionDenied, "x")), false)
    XCTAssertEqual(try retryable(Envelope.failure(.notFound, "x")), false)
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
