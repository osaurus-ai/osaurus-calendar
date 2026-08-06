import Foundation
import XCTest

@testable import osaurus_calendar

final class ValidationTests: XCTestCase {

  func testNilLimitUsesDefault() {
    XCTAssertEqual(Validation.resolveLimit(nil, default: 10), .ok(10))
  }

  func testPositiveLimitPassesThrough() {
    XCTAssertEqual(Validation.resolveLimit(5, default: 10), .ok(5))
  }

  func testNegativeLimitRejected() {
    // Regression: a negative limit used to reach prefix(_:) and trap at runtime.
    guard case .invalid = Validation.resolveLimit(-1, default: 10) else {
      return XCTFail("Negative limit must be rejected as invalid_args")
    }
  }

  func testZeroLimitRejected() {
    guard case .invalid = Validation.resolveLimit(0, default: 10) else {
      return XCTFail("Zero limit must be rejected as invalid_args")
    }
  }

  func testHugeLimitClamped() {
    XCTAssertEqual(
      Validation.resolveLimit(Int.max, default: 10), .ok(Validation.maxLimit))
  }

  func testEncodingFailureReturnsCanonicalFailureInsteadOfFakeResult() throws {
    struct FailingValue: Encodable {
      func encode(to encoder: Encoder) throws {
        throw EncodingError.invalidValue(
          "value",
          EncodingError.Context(codingPath: [], debugDescription: "intentional"))
      }
    }

    let json = encodeSuccess(FailingValue(), tool: "query_events")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    XCTAssertEqual(object["ok"] as? Bool, false)
    XCTAssertEqual(object["kind"] as? String, "execution_error")
    XCTAssertEqual(object["retryable"] as? Bool, false)
    XCTAssertEqual(object["tool"] as? String, "query_events")
  }
}
