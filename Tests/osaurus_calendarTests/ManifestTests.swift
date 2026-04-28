import Foundation
import XCTest

@testable import osaurus_calendar

final class ManifestTests: XCTestCase {

  private enum ManifestError: Error {
    case entryPointFailed
    case nilManifest
    case invalidJSON
  }

  private func loadManifest() throws -> [String: Any] {
    guard let apiPtr = osaurus_plugin_entry() else {
      throw ManifestError.entryPointFailed
    }

    let fnPtrSize = MemoryLayout<UnsafeRawPointer?>.stride
    let initPtr = apiPtr.load(
      fromByteOffset: fnPtrSize,
      as: (@convention(c) () -> UnsafeMutableRawPointer?).self)
    let ctx = initPtr()

    let getManifestPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 3,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?).self)
    guard let cStr = getManifestPtr(ctx) else {
      throw ManifestError.nilManifest
    }
    let jsonString = String(cString: cStr)

    let freeStringPtr = apiPtr.load(
      fromByteOffset: 0,
      as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self)
    freeStringPtr(cStr)

    let destroyPtr = apiPtr.load(
      fromByteOffset: fnPtrSize * 2,
      as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    destroyPtr(ctx)

    guard let data = jsonString.data(using: .utf8),
      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw ManifestError.invalidJSON
    }
    return manifest
  }

  private func tools(from manifest: [String: Any]) -> [[String: Any]] {
    let capabilities = manifest["capabilities"] as? [String: Any]
    return capabilities?["tools"] as? [[String: Any]] ?? []
  }

  func testManifestPluginIdentity() throws {
    let manifest = try loadManifest()
    XCTAssertEqual(manifest["plugin_id"] as? String, "osaurus.calendar")
    XCTAssertEqual(manifest["version"] as? String, "1.0.5")
  }

  func testManifestToolIDs() throws {
    let manifest = try loadManifest()
    let ids = Set(tools(from: manifest).compactMap { $0["id"] as? String })
    XCTAssertEqual(ids, ["get_events", "search_events", "create_event", "open_event"])
  }

  func testManifestPermissionPolicies() throws {
    let manifest = try loadManifest()
    let toolMap = Dictionary(
      uniqueKeysWithValues: tools(from: manifest).compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })

    XCTAssertEqual(toolMap["get_events"]?["permission_policy"] as? String, "auto")
    XCTAssertEqual(toolMap["search_events"]?["permission_policy"] as? String, "auto")
    XCTAssertEqual(toolMap["create_event"]?["permission_policy"] as? String, "ask")
    XCTAssertEqual(toolMap["open_event"]?["permission_policy"] as? String, "auto")
  }

  func testManifestRequirements() throws {
    let manifest = try loadManifest()
    let toolMap = Dictionary(
      uniqueKeysWithValues: tools(from: manifest).compactMap { tool -> (String, [String: Any])? in
        guard let id = tool["id"] as? String else { return nil }
        return (id, tool)
      })

    for id in ["get_events", "search_events", "create_event", "open_event"] {
      let requirements = toolMap[id]?["requirements"] as? [String] ?? []
      XCTAssertTrue(requirements.contains("calendar"), "\(id) should require calendar access")
    }

    let openRequirements = toolMap["open_event"]?["requirements"] as? [String] ?? []
    XCTAssertTrue(openRequirements.contains("automation"))
  }
}
