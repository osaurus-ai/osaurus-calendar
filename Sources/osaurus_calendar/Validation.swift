import Foundation

/// Pure argument-validation helpers, kept framework-free so they can be unit
/// tested without EventKit/TCC access.
enum Validation {
  static let maxLimit = 1000

  enum LimitResult: Equatable {
    case ok(Int)
    case invalid(String)
  }

  /// Resolves a requested limit against a default, rejecting non-positive
  /// values (negative values trap in `prefix(_:)`) and clamping huge ones.
  static func resolveLimit(_ requested: Int?, default defaultLimit: Int) -> LimitResult {
    guard let requested else { return .ok(defaultLimit) }
    guard requested > 0 else {
      return .invalid("limit must be a positive integer, got \(requested)")
    }
    return .ok(min(requested, maxLimit))
  }
}
