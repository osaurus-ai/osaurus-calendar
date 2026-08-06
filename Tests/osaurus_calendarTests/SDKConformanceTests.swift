import Foundation
import OsaurusPluginABI
import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_calendar

/// SDK conformance checks: manifest shape, ABI entry-point contract, and the
/// canonical failure envelope, all via OsaurusPluginTestSupport.
final class SDKConformanceTests: XCTestCase {

  private func invoke(tool: String, payload: String) throws -> [String: Any] {
    let entry = try XCTUnwrap(osaurus_plugin_entry_v2(nil))
    let api = entry.assumingMemoryBound(to: OsrPluginAPI.self).pointee
    let context = try XCTUnwrap(api.`init`?())
    defer { api.destroy?(context) }

    let resultPointer = "tool".withCString { type in
      tool.withCString { id in
        payload.withCString { arguments in
          api.invoke?(context, type, id, arguments)
        }
      }
    }
    let pointer = try XCTUnwrap(resultPointer ?? nil)
    defer { api.free_string?(pointer) }
    let json = String(cString: pointer)
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
  }

  func testManifestConformance() throws {
    try ManifestConformance.assertConformant(calendarManifestJSON)
  }

  func testV2EntryConformance() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry_v2(nil), manifestJSON: calendarManifestJSON)
  }

  func testV1EntryConformance() throws {
    try ABIConformance.assertEntryConformance(
      osaurus_plugin_entry(), manifestJSON: calendarManifestJSON)
  }

  func testInvokeReturnsCanonicalFailure() throws {
    // Malformed args fail before any EventKit/TCC access, exercised through
    // the real ABI invoke callback.
    let result = try invoke(tool: "query_events", payload: "not json")
    XCTAssertEqual(result["ok"] as? Bool, false)
    XCTAssertEqual(result["kind"] as? String, Envelope.Kind.invalidArgs.rawValue)
    XCTAssertEqual(result["retryable"] as? Bool, true)
    XCTAssertEqual(result["tool"] as? String, "query_events")
  }

  func testLegacyToolNamesAreToolNotFound() throws {
    for legacyName in ["get_events", "search_events"] {
      let result = try invoke(tool: legacyName, payload: "{}")
      XCTAssertEqual(result["kind"] as? String, Envelope.Kind.toolNotFound.rawValue)
      XCTAssertEqual(result["retryable"] as? Bool, false)
      XCTAssertEqual(result["tool"] as? String, legacyName)
    }
  }

  func testRuntimeRejectsUnknownArgumentsBeforeCalendarAccess() throws {
    let result = try invoke(
      tool: "query_events",
      payload: #"{"fromDate":"2026-08-06T00:00:00Z"}"#)
    XCTAssertEqual(result["kind"] as? String, Envelope.Kind.invalidArgs.rawValue)
    XCTAssertEqual(result["field"] as? String, "fromDate")
    XCTAssertEqual(result["tool"] as? String, "query_events")
  }

  func testRuntimeRequiresRFC3339Timestamps() throws {
    let result = try invoke(
      tool: "query_events",
      payload: #"{"range_start":"2026-08-06"}"#)
    XCTAssertEqual(result["kind"] as? String, Envelope.Kind.invalidArgs.rawValue)
    XCTAssertEqual(result["field"] as? String, "range_start")
    XCTAssertEqual(result["tool"] as? String, "query_events")
  }
}
