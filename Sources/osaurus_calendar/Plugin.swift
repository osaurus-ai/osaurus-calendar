import EventKit
import Foundation
import OsaurusPluginABI
import OsaurusPluginKit

// MARK: - EventKit Helper

enum CalendarAccess {
  case granted
  case denied
  case timedOut
}

private class CalendarManager {
  static let shared = CalendarManager()
  let store = EKEventStore()

  private init() {}

  func ensureAccess() -> CalendarAccess {
    // If called from the main thread, dispatch to a background queue to avoid
    // deadlocking when the EventKit permission callback needs the main thread.
    if Thread.isMainThread {
      var result: CalendarAccess = .timedOut
      let semaphore = DispatchSemaphore(value: 0)
      DispatchQueue.global(qos: .userInitiated).async {
        result = self._ensureAccess()
        semaphore.signal()
      }
      let waitResult = semaphore.wait(timeout: .now() + 35)
      return waitResult == .timedOut ? .timedOut : result
    }
    return _ensureAccess()
  }

  private func _ensureAccess() -> CalendarAccess {
    let status = EKEventStore.authorizationStatus(for: .event)

    switch status {
    case .authorized, .fullAccess:
      return .granted
    case .notDetermined:
      return requestAccess()
    case .denied, .restricted, .writeOnly:
      return .denied
    @unknown default:
      return .denied
    }
  }

  private func requestAccess() -> CalendarAccess {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false

    if #available(macOS 14.0, *) {
      store.requestFullAccessToEvents { isGranted, _ in
        granted = isGranted
        semaphore.signal()
      }
    } else {
      store.requestAccess(to: .event) { isGranted, _ in
        granted = isGranted
        semaphore.signal()
      }
    }

    let result = semaphore.wait(timeout: .now() + 30)
    if result == .timedOut {
      return .timedOut
    }
    return granted ? .granted : .denied
  }
}

/// Returns a failure envelope for non-granted access, or nil when granted.
private func calendarAccessFailure(_ access: CalendarAccess, tool: String) -> String? {
  switch access {
  case .granted:
    return nil
  case .denied:
    return Envelope.failure(
      .userDenied,
      "Calendar access denied. Enable it in System Settings > Privacy & Security > Calendars.",
      tool: tool)
  case .timedOut:
    return Envelope.failure(
      .timeout, "Timed out waiting for Calendar permission", tool: tool)
  }
}

// MARK: - Calendar Event Model

private struct CalendarEvent: Codable {
  let eventId: String
  let title: String
  let location: String?
  let notes: String?
  let startAt: String
  let endAt: String
  let calendarId: String
  let calendarName: String
  let accountName: String
  let isAllDay: Bool
  let url: String?

  enum CodingKeys: String, CodingKey {
    case eventId = "event_id"
    case title
    case location
    case notes
    case startAt = "start_at"
    case endAt = "end_at"
    case calendarId = "calendar_id"
    case calendarName = "calendar_name"
    case accountName = "account_name"
    case isAllDay = "is_all_day"
    case url
  }
}

/// List-style responses carry the full match count so a truncated result is
/// visible to the model instead of silently reading as "these are all the
/// events" (small models otherwise report a clipped list as complete).
private struct EventListResponse: Codable {
  let events: [CalendarEvent]
  let returnedCount: Int
  let totalCount: Int
  let truncated: Bool
  let rangeStart: String
  let rangeEnd: String

  enum CodingKeys: String, CodingKey {
    case events
    case returnedCount = "returned_count"
    case totalCount = "total_count"
    case truncated
    case rangeStart = "range_start"
    case rangeEnd = "range_end"
  }
}

private func makeEventListResponse(
  matching: [EKEvent], limit: Int, startDate: Date, endDate: Date
) -> EventListResponse {
  let sorted = matching.sorted { $0.startDate < $1.startDate }
  let clipped = sorted.prefix(limit).map(mapEvent)
  return EventListResponse(
    events: clipped,
    returnedCount: clipped.count,
    totalCount: sorted.count,
    truncated: sorted.count > clipped.count,
    rangeStart: rfc3339Formatter.string(from: startDate),
    rangeEnd: rfc3339Formatter.string(from: endDate)
  )
}

// MARK: - Date Parsing

private let rfc3339Formatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  // Emit dates in the user's local time zone (with UTC offset) rather than
  // "Z"/UTC, so listed event times match what Calendar.app shows. Parsing is
  // unaffected: input strings carry their own offset.
  formatter.timeZone = TimeZone.current
  return formatter
}()

private let fractionalRFC3339Formatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  return formatter
}()

private func parseRFC3339(_ value: String) -> Date? {
  rfc3339Formatter.date(from: value) ?? fractionalRFC3339Formatter.date(from: value)
}

// MARK: - Event Mapping

private func mapEvent(_ event: EKEvent) -> CalendarEvent {
  CalendarEvent(
    eventId: event.eventIdentifier ?? event.calendarItemIdentifier,
    title: event.title,
    location: event.location,
    notes: event.notes,
    startAt: rfc3339Formatter.string(from: event.startDate),
    endAt: rfc3339Formatter.string(from: event.endDate),
    calendarId: event.calendar.calendarIdentifier,
    calendarName: event.calendar.title,
    accountName: event.calendar.source?.title ?? "Unknown",
    isAllDay: event.isAllDay,
    url: event.url?.absoluteString
  )
}

// MARK: - Calendar Model

private struct CalendarInfo: Codable {
  let calendarId: String
  let calendarName: String
  let accountName: String
  let isWritable: Bool
  let isDefault: Bool

  enum CodingKeys: String, CodingKey {
    case calendarId = "calendar_id"
    case calendarName = "calendar_name"
    case accountName = "account_name"
    case isWritable = "is_writable"
    case isDefault = "is_default"
  }
}

private struct CalendarListResponse: Codable {
  let calendars: [CalendarInfo]
  let returnedCount: Int
  let totalCount: Int
  let truncated: Bool

  enum CodingKeys: String, CodingKey {
    case calendars
    case returnedCount = "returned_count"
    case totalCount = "total_count"
    case truncated
  }
}

private func mapCalendar(_ calendar: EKCalendar, defaultId: String?) -> CalendarInfo {
  CalendarInfo(
    calendarId: calendar.calendarIdentifier,
    calendarName: calendar.title,
    accountName: calendar.source?.title ?? "Unknown",
    isWritable: calendar.allowsContentModifications,
    isDefault: calendar.calendarIdentifier == defaultId
  )
}

// MARK: - Calendar Tools

private struct ListCalendarsTool {
  let name = "list_calendars"
  private let maximumCalendars = 200

  func run(args: String) -> String {
    do {
      _ = try decodeArgs(
        EmptyArgs.self, from: args, allowedKeys: [], tool: name)
    } catch {
      return renderFailure(error, tool: name)
    }

    if let failure = calendarAccessFailure(
      CalendarManager.shared.ensureAccess(), tool: name)
    {
      return failure
    }

    let store = CalendarManager.shared.store
    let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
    let allCalendars = store.calendars(for: .event)
      .sorted {
        ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
      }
    let calendars = allCalendars.prefix(maximumCalendars)
      .map { mapCalendar($0, defaultId: defaultId) }
    let response = CalendarListResponse(
      calendars: calendars,
      returnedCount: calendars.count,
      totalCount: allCalendars.count,
      truncated: allCalendars.count > calendars.count)

    return encodeSuccess(response, tool: name)
  }
}

private struct QueryEventsTool {
  let name = "query_events"

  struct Args: Decodable {
    let query: String?
    let limit: Int?
    let rangeStart: String?
    let rangeEnd: String?
  }

  func run(args: String) -> String {
    let input: Args
    do {
      input = try decodeArgs(
        Args.self,
        from: args,
        allowedKeys: ["query", "limit", "range_start", "range_end"],
        tool: name)
    } catch {
      return renderFailure(error, tool: name)
    }

    let normalizedQuery = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
    if input.query != nil && normalizedQuery?.isEmpty != false {
      return Envelope.failure(
        .invalidArgs,
        "query must not be empty when provided",
        field: "query",
        expected: "a non-empty string",
        tool: name)
    }

    let limit: Int
    switch Validation.resolveLimit(input.limit, default: Validation.defaultLimit) {
    case .ok(let value):
      limit = value
    case .invalid(let message):
      return Envelope.failure(
        .invalidArgs,
        message,
        field: "limit",
        expected: "an integer from 1 through \(Validation.maxLimit)",
        tool: name)
    }

    let now = Date()
    let defaultEndDate = Calendar.current.date(byAdding: .day, value: 7, to: now)!
    let startDate: Date
    if let rangeStart = input.rangeStart {
      guard let parsed = parseRFC3339(rangeStart) else {
        return Envelope.failure(
          .invalidArgs,
          "range_start must be an RFC 3339 timestamp",
          field: "range_start",
          expected: "RFC 3339 date-time, for example 2026-08-06T09:00:00-07:00",
          tool: name)
      }
      startDate = parsed
    } else {
      startDate = now
    }

    let endDate: Date
    if let rangeEnd = input.rangeEnd {
      guard let parsed = parseRFC3339(rangeEnd) else {
        return Envelope.failure(
          .invalidArgs,
          "range_end must be an RFC 3339 timestamp",
          field: "range_end",
          expected: "RFC 3339 date-time, for example 2026-08-13T09:00:00-07:00",
          tool: name)
      }
      endDate = parsed
    } else {
      endDate = defaultEndDate
    }

    guard endDate >= startDate else {
      return Envelope.failure(
        .invalidArgs,
        "range_end must be on or after range_start",
        field: "range_end",
        expected: "a timestamp on or after range_start",
        tool: name)
    }

    if let failure = calendarAccessFailure(
      CalendarManager.shared.ensureAccess(), tool: name)
    {
      return failure
    }

    let store = CalendarManager.shared.store
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)

    guard let allEvents = fetchEvents(store: store, predicate: predicate) else {
      return Envelope.failure(.timeout, "Calendar query timed out", tool: name)
    }

    let matching: [EKEvent]
    if let query = normalizedQuery?.lowercased() {
      matching = allEvents.filter { $0.title.lowercased().contains(query) }
    } else {
      matching = allEvents
    }
    let response = makeEventListResponse(
      matching: matching, limit: limit, startDate: startDate, endDate: endDate)
    let warnings =
      response.truncated
      ? ["Returned \(response.returnedCount) of \(response.totalCount) matching events."]
      : []
    return encodeSuccess(response, tool: name, warnings: warnings)
  }
}

private struct CreateEventTool {
  let name = "create_event"

  struct Args: Decodable {
    let title: String
    let startAt: String
    let endAt: String
    let location: String?
    let notes: String?
    let isAllDay: Bool?
    let calendarName: String?
    let accountName: String?
  }

  /// Resolves the target calendar for the new event, or returns a failure
  /// envelope. With two or more accounts, calendar titles are often
  /// duplicated across accounts ("Home", "Work"), so a bare title match can
  /// silently target the wrong account or a read-only calendar. Resolution
  /// is explicit: an unmatched name is an error (never a silent fallback to
  /// the default calendar), and an ambiguous name asks for `account_name`.
  private enum CalendarResolution {
    case success(EKCalendar)
    /// Carries a ready-to-return failure envelope JSON string.
    case failure(String)
  }

  private func resolveCalendar(store: EKEventStore, input: Args) -> CalendarResolution {
    guard let calendarName = input.calendarName else {
      if let accountName = input.accountName {
        let matches = store.calendars(for: .event)
          .filter { $0.source?.title == accountName && $0.allowsContentModifications }
        if let cal = matches.first, matches.count == 1 {
          return .success(cal)
        }
        return .failure(
          Envelope.failure(
            .invalidArgs,
            matches.isEmpty
              ? "No writable calendar found for account '\(accountName)'. Use list_calendars to see available calendars."
              : "Account '\(accountName)' has multiple writable calendars. Specify calendar_name: \(matches.map { $0.title }.joined(separator: ", "))",
            tool: name
          ))
      }
      guard let cal = store.defaultCalendarForNewEvents else {
        return .failure(
          Envelope.failure(
            .unavailable,
            "No default calendar is configured. Specify calendar_name after calling list_calendars.",
            tool: name))
      }
      return .success(cal)
    }

    var matches = store.calendars(for: .event).filter { $0.title == calendarName }
    if let accountName = input.accountName {
      matches = matches.filter { $0.source?.title == accountName }
    }

    guard !matches.isEmpty else {
      let scope = input.accountName.map { " in account '\($0)'" } ?? ""
      return .failure(
        Envelope.failure(
          .notFound,
          "Calendar '\(calendarName)' not found\(scope). Use list_calendars to see available calendars.",
          tool: name
        ))
    }

    let writable = matches.filter { $0.allowsContentModifications }
    guard !writable.isEmpty else {
      return .failure(
        Envelope.failure(
          .rejected,
          "Calendar '\(calendarName)' is read-only. Use list_calendars to find a writable calendar.",
          tool: name
        ))
    }

    guard writable.count == 1 else {
      let accounts = writable.map { $0.source?.title ?? "Unknown" }.joined(separator: ", ")
      return .failure(
        Envelope.failure(
          .invalidArgs,
          "Multiple calendars named '\(calendarName)' exist (accounts: \(accounts)). Specify account_name to disambiguate.",
          field: "account_name",
          expected: "one of: \(accounts)",
          tool: name
        ))
    }

    return .success(writable[0])
  }

  func run(args: String) -> String {
    let input: Args
    do {
      input = try decodeArgs(
        Args.self,
        from: args,
        allowedKeys: [
          "title", "start_at", "end_at", "location", "notes", "is_all_day",
          "calendar_name", "account_name",
        ],
        tool: name)
    } catch {
      return renderFailure(error, tool: name)
    }

    guard !input.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Envelope.failure(
        .invalidArgs,
        "title must not be empty",
        field: "title",
        expected: "a non-empty string",
        tool: name)
    }

    guard let startDate = parseRFC3339(input.startAt) else {
      return Envelope.failure(
        .invalidArgs,
        "start_at must be an RFC 3339 timestamp",
        field: "start_at",
        expected: "RFC 3339 date-time, for example 2026-08-06T09:00:00-07:00",
        tool: name)
    }

    guard let endDate = parseRFC3339(input.endAt) else {
      return Envelope.failure(
        .invalidArgs,
        "end_at must be an RFC 3339 timestamp",
        field: "end_at",
        expected: "RFC 3339 date-time, for example 2026-08-06T10:00:00-07:00",
        tool: name)
    }

    guard endDate > startDate else {
      return Envelope.failure(
        .invalidArgs,
        "end_at must be after start_at",
        field: "end_at",
        expected: "a timestamp after start_at",
        tool: name)
    }

    if let failure = calendarAccessFailure(
      CalendarManager.shared.ensureAccess(), tool: name)
    {
      return failure
    }

    let store = CalendarManager.shared.store

    let calendar: EKCalendar
    switch resolveCalendar(store: store, input: input) {
    case .success(let cal): calendar = cal
    case .failure(let envelope): return envelope
    }

    let event = EKEvent(eventStore: store)
    event.title = input.title
    event.startDate = startDate
    event.endDate = endDate
    event.location = input.location
    event.notes = input.notes
    event.isAllDay = input.isAllDay ?? false
    event.calendar = calendar

    do {
      try store.save(event, span: .thisEvent)
      return encodeSuccess(mapEvent(event), tool: name)
    } catch {
      return Envelope.failure(.executionError, error.localizedDescription, tool: name)
    }
  }
}

private struct OpenEventTool {
  let name = "open_event"

  struct Args: Decodable {
    let eventId: String
  }

  func run(args: String) -> String {
    let input: Args
    do {
      input = try decodeArgs(
        Args.self, from: args, allowedKeys: ["event_id"], tool: name)
    } catch {
      return renderFailure(error, tool: name)
    }

    guard !input.eventId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return Envelope.failure(
        .invalidArgs,
        "event_id must not be empty",
        field: "event_id",
        expected: "a stable event_id returned by query_events or create_event",
        tool: name)
    }

    if let failure = calendarAccessFailure(
      CalendarManager.shared.ensureAccess(), tool: name)
    {
      return failure
    }

    let store = CalendarManager.shared.store
    guard let event = store.event(withIdentifier: input.eventId) else {
      return Envelope.failure(
        .notFound, "Event not found: \(input.eventId)", tool: name)
    }

    let appleScriptDateFormatter = DateFormatter()
    appleScriptDateFormatter.dateStyle = .full
    appleScriptDateFormatter.timeStyle = .medium
    let dateString = appleScriptDateFormatter.string(from: event.startDate)

    let eventId = event.eventIdentifier ?? input.eventId
    let calendarTitle = escapeAppleScript(event.calendar.title)
    let safeEventId = escapeAppleScript(eventId)
    let safeDateString = escapeAppleScript(dateString)

    let script = """
      tell application "Calendar"
          activate
          set found to false
          repeat with cal in calendars
              if name of cal is "\(calendarTitle)" then
                  try
                      set evt to (first event of cal whose uid is "\(safeEventId)")
                      show evt
                      set found to true
                      exit repeat
                  end try
              end if
          end repeat
          if not found then
              -- Fallback: switch to date
              switch view to day view
              view calendar date (date "\(safeDateString)")
          end if
      end tell
      """

    // Run AppleScript via osascript process (thread-safe, with timeout)
    let result = runAppleScript(script)
    if result.success {
      return Envelope.success(
        tool: name,
        result: [
          "event_id": eventId,
          "opened": true,
        ])
    } else if result.timedOut {
      return Envelope.failure(.timeout, result.error, tool: name)
    } else if isAutomationDenied(result.error) {
      return Envelope.failure(
        .userDenied,
        "Automation access to Calendar was denied. Enable it in System Settings > Privacy & Security > Automation.",
        tool: name)
    } else {
      return Envelope.failure(.executionError, result.error, tool: name)
    }
  }
}

// MARK: - Helper Functions

/// Runs an AppleScript via /usr/bin/osascript through the SDK's ProcessRunner
/// (thread-safe, concurrent stream draining, SIGTERM→SIGKILL on timeout).
private func runAppleScript(_ source: String, timeout: TimeInterval = 15) -> (
  success: Bool, timedOut: Bool, output: String, error: String
) {
  let result: ProcessRunner.Output
  do {
    result = try ProcessRunner.run(
      executable: "/usr/bin/osascript", arguments: ["-e", source], timeout: timeout)
  } catch ProcessRunnerError.launchFailed(let reason) {
    return (false, false, "", reason)
  } catch {
    return (false, false, "", error.localizedDescription)
  }

  let output = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
  let errOutput = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

  return (
    result.exitStatus == 0 && !result.timedOut,
    result.timedOut,
    output,
    result.timedOut ? "AppleScript timed out after \(Int(timeout)) seconds" : errOutput
  )
}

private func isAutomationDenied(_ message: String) -> Bool {
  let normalized = message.lowercased()
  return normalized.contains("-1743")
    || normalized.contains("not authorized to send apple events")
    || normalized.contains("not authorised to send apple events")
}

/// Fetches events from EventKit with a timeout to prevent blocking indefinitely.
/// Returns nil on timeout; the result is handed over under a lock so a late
/// completion cannot race with the timed-out reader.
private func fetchEvents(store: EKEventStore, predicate: NSPredicate, timeout: TimeInterval = 10)
  -> [EKEvent]?
{
  let box = ResultBox<[EKEvent]>()
  let semaphore = DispatchSemaphore(value: 0)

  DispatchQueue.global(qos: .userInitiated).async {
    box.set(store.events(matching: predicate))
    semaphore.signal()
  }

  let result = semaphore.wait(timeout: .now() + timeout)
  return result == .timedOut ? nil : box.get()
}

/// Thread-safe container for handing a result across the semaphore boundary.
private final class ResultBox<T> {
  private let lock = NSLock()
  private var value: T?

  func set(_ newValue: T) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> T? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

/// Escapes a string so it can be safely embedded inside an AppleScript string
/// literal (double-quoted), preventing injection via backslashes or quotes.
private func escapeAppleScript(_ str: String) -> String {
  return
    str
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
}

private struct EmptyArgs: Decodable {}

private func decodeArgs<T: Decodable>(
  _ type: T.Type,
  from json: String,
  allowedKeys: Set<String>,
  tool: String
) throws -> T {
  let object = try ArgValidation.parseObject(json)
  if let unknown = object.keys.filter({ !allowedKeys.contains($0) }).sorted().first {
    throw EnvelopeFailure(
      .invalidArgs,
      "Unknown argument: \(unknown)",
      field: unknown,
      expected: "one of: \(allowedKeys.sorted().joined(separator: ", "))",
      tool: tool)
  }

  do {
    let data = try JSONSerialization.data(withJSONObject: object)
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(type, from: data)
  } catch {
    throw EnvelopeFailure(
      .invalidArgs,
      "Arguments do not match the \(tool) contract",
      tool: tool)
  }
}

private func renderFailure(_ error: Error, tool: String) -> String {
  guard let failure = error as? EnvelopeFailure else {
    return Envelope.failure(.executionError, error.localizedDescription, tool: tool)
  }
  return Envelope.failure(
    failure.kind,
    failure.message,
    retryable: failure.retryable,
    field: failure.field,
    expected: failure.expected,
    tool: failure.tool ?? tool,
    dataJSON: failure.dataJSON)
}

private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let data = try encoder.encode(value)
  guard let json = String(data: data, encoding: .utf8) else {
    throw EncodingError.invalidValue(
      value,
      EncodingError.Context(
        codingPath: [], debugDescription: "Encoded JSON was not valid UTF-8"))
  }
  return json
}

func encodeSuccess<T: Encodable>(
  _ value: T,
  tool: String,
  warnings: [String] = []
) -> String {
  do {
    return Envelope.success(
      tool: tool, rawResult: try encodeJSON(value), warnings: warnings)
  } catch {
    return Envelope.failure(
      .executionError,
      "Failed to encode \(tool) result: \(error.localizedDescription)",
      retryable: false,
      tool: tool)
  }
}

// MARK: - C ABI Surface

private class PluginContext {
  let listCalendarsTool = ListCalendarsTool()
  let queryEventsTool = QueryEventsTool()
  let createEventTool = CreateEventTool()
  let openEventTool = OpenEventTool()
}

private var pluginAPI = PluginEntry.makeAPI(
  version: OsrABIVersion.v2,
  init: {
    Unmanaged.passRetained(PluginContext()).toOpaque()
  },
  destroy: { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  },
  getManifest: { _ in
    osrMakeCString(calendarManifestJSON)
  },
  invoke: { ctxPtr, typePtr, idPtr, payloadPtr in
    guard let ctxPtr = ctxPtr,
      let typePtr = typePtr,
      let idPtr = idPtr,
      let payloadPtr = payloadPtr
    else { return nil }

    let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
    let type = String(cString: typePtr)
    let id = String(cString: idPtr)
    let payload = String(cString: payloadPtr)

    guard type == "tool" else {
      return osrMakeCString(
        Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
    }

    switch id {
    case ctx.listCalendarsTool.name:
      return osrMakeCString(ctx.listCalendarsTool.run(args: payload))
    case ctx.queryEventsTool.name:
      return osrMakeCString(ctx.queryEventsTool.run(args: payload))
    case ctx.createEventTool.name:
      return osrMakeCString(ctx.createEventTool.run(args: payload))
    case ctx.openEventTool.name:
      return osrMakeCString(ctx.openEventTool.run(args: payload))
    default:
      return osrMakeCString(
        Envelope.failure(.toolNotFound, "Unknown tool: \(id)", tool: id))
    }
  }
)

/// File-scope manifest JSON embedded by the plugin. Referenced from `get_manifest`.
let calendarManifestJSON = """
      {
        "plugin_id": "osaurus.calendar",
        "name": "Calendar",
        "version": "2.0.0",
        "description": "Read, create, and open events in macOS Calendar.app",
        "license": "MIT",
        "authors": ["Osaurus"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "list_calendars",
              "description": "List up to 200 calendars with stable IDs, account names, writability, default status, and collection metadata.",
              "parameters": {
                "type": "object",
                "properties": {},
                "required": [],
                "additionalProperties": false
              },
              "requirements": ["calendar"],
              "permission_policy": "auto"
            },
            {
              "id": "query_events",
              "description": "List events in an RFC 3339 range, optionally filtering titles by a case-insensitive query. Returns stable IDs, local-offset RFC 3339 timestamps, account names, and bounded collection metadata.",
              "parameters": {
                "type": "object",
                "properties": {
                  "query": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Optional case-insensitive substring to match in event titles."
                  },
                  "limit": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": 200,
                    "default": 50,
                    "description": "Maximum number of matching events to return."
                  },
                  "range_start": {
                    "type": "string",
                    "format": "date-time",
                    "description": "Inclusive range start as an RFC 3339 timestamp. Defaults to the current time."
                  },
                  "range_end": {
                    "type": "string",
                    "format": "date-time",
                    "description": "Range end as an RFC 3339 timestamp. Defaults to seven days after the current time."
                  }
                },
                "required": [],
                "additionalProperties": false
              },
              "requirements": ["calendar"],
              "permission_policy": "auto"
            },
            {
              "id": "create_event",
              "description": "Create an event and return the complete created event. Uses the default calendar unless calendar_name or account_name selects one.",
              "parameters": {
                "type": "object",
                "properties": {
                  "title": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Event title."
                  },
                  "start_at": {
                    "type": "string",
                    "format": "date-time",
                    "description": "Event start as an RFC 3339 timestamp."
                  },
                  "end_at": {
                    "type": "string",
                    "format": "date-time",
                    "description": "Event end as an RFC 3339 timestamp later than start_at."
                  },
                  "location": {
                    "type": "string",
                    "description": "Optional event location."
                  },
                  "notes": {
                    "type": "string",
                    "description": "Optional event notes."
                  },
                  "is_all_day": {
                    "type": "boolean",
                    "default": false,
                    "description": "Whether the event is all-day."
                  },
                  "calendar_name": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Calendar name. If duplicated across accounts, also provide account_name."
                  },
                  "account_name": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Calendar account name returned by list_calendars."
                  }
                },
                "required": ["title", "start_at", "end_at"],
                "additionalProperties": false
              },
              "requirements": ["calendar"],
              "permission_policy": "ask"
            },
            {
              "id": "open_event",
              "description": "Open a specific calendar event in the Calendar app",
              "parameters": {
                "type": "object",
                "properties": {
                  "event_id": {
                    "type": "string",
                    "minLength": 1,
                    "description": "Stable event ID returned by query_events or create_event."
                  }
                },
                "required": ["event_id"],
                "additionalProperties": false
              },
              "requirements": ["calendar", "automation"],
              "permission_policy": "ask"
            }
          ]
        }
      }
      """

@_cdecl("osaurus_plugin_entry_v2")
public func osaurus_plugin_entry_v2(_ host: UnsafeRawPointer?) -> UnsafeRawPointer? {
  PluginEntry.enterV2(host, api: &pluginAPI)
}

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  PluginEntry.enterV1(api: &pluginAPI)
}
