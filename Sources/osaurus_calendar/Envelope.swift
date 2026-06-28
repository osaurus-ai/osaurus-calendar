import Foundation

/// Canonical response envelope for the Osaurus host contract.
///
/// The host AUTO-WRAPS any non-envelope output from a tool as a SUCCESS. To make
/// failures classify correctly, every error path MUST return a canonical failure
/// envelope: {"ok":false,"kind":"<kind>","message":"...","retryable":<bool>}.
enum Envelope {
  enum Kind: String {
    case invalidArgs = "invalid_args"
    case executionError = "execution_error"
    case notFound = "not_found"
    case unavailable = "unavailable"
  }

  static func failure(_ kind: Kind, _ message: String, retryable: Bool? = nil) -> String {
    let retry = retryable ?? defaultRetryable(for: kind)
    return
      "{\"ok\":false,\"kind\":\"\(kind.rawValue)\",\"message\":\"\(escape(message))\",\"retryable\":\(retry)}"
  }

  static func successRaw(_ jsonPayload: String) -> String { "{\"ok\":true,\"result\":\(jsonPayload)}" }

  private static func defaultRetryable(for kind: Kind) -> Bool {
    switch kind {
    case .invalidArgs, .executionError, .unavailable: return true
    case .notFound: return false
    }
  }

  static func escape(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count + 2)
    for ch in s {
      switch ch {
      case "\\": out += "\\\\"
      case "\"": out += "\\\""
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      default:
        if let a = ch.asciiValue, a < 0x20 {
          out += String(format: "\\u%04x", a)
        } else {
          out.append(ch)
        }
      }
    }
    return out
  }
}
