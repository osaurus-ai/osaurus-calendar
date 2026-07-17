import OsaurusPluginABI
import OsaurusPluginKit
import OsaurusPluginTestSupport
import XCTest

@testable import osaurus_calendar

/// SDK conformance checks: manifest shape, ABI entry-point contract, and the
/// canonical failure envelope, all via OsaurusPluginTestSupport.
final class SDKConformanceTests: XCTestCase {

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
    let entry = try XCTUnwrap(osaurus_plugin_entry_v2(nil))
    let api = entry.assumingMemoryBound(to: OsrPluginAPI.self).pointee
    let ctx = try XCTUnwrap(api.`init`?())
    defer { api.destroy?(ctx) }

    let resultPtr = "tool".withCString { type in
      "get_events".withCString { id in
        "not json".withCString { payload in
          api.invoke?(ctx, type, id, payload)
        }
      }
    }
    let ptr = try XCTUnwrap(resultPtr ?? nil)
    let json = String(cString: ptr)
    api.free_string?(ptr)

    try assertCanonicalFailure(json, kind: .invalidArgs)
  }
}
