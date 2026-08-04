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
private func calendarAccessFailure(_ access: CalendarAccess) -> String? {
  switch access {
  case .granted:
    return nil
  case .denied:
    return Envelope.failure(
      .permissionDenied,
      "Calendar access denied. Enable it in System Settings > Privacy & Security > Calendars.")
  case .timedOut:
    return Envelope.failure(.timeout, "Timed out waiting for Calendar permission")
  }
}

// MARK: - Calendar Event Model

private struct CalendarEvent: Codable {
  let id: String
  let title: String
  let location: String?
  let notes: String?
  let startDate: String?
  let endDate: String?
  let calendarName: String
  let isAllDay: Bool
  let url: String?
}

// MARK: - Date Parsing

private let isoDateFormatter: ISO8601DateFormatter = {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [
    .withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
  ]
  return formatter
}()

private let simpleDateFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()

private func parseDate(_ str: String) -> Date? {
  if let date = isoDateFormatter.date(from: str) { return date }
  if let date = simpleDateFormatter.date(from: str) { return date }
  return nil
}

// MARK: - Event Mapping

private func mapEvent(_ event: EKEvent) -> CalendarEvent {
  CalendarEvent(
    id: event.eventIdentifier,
    title: event.title,
    location: event.location,
    notes: event.notes,
    startDate: isoDateFormatter.string(from: event.startDate),
    endDate: isoDateFormatter.string(from: event.endDate),
    calendarName: event.calendar.title,
    isAllDay: event.isAllDay,
    url: event.url?.absoluteString
  )
}

// MARK: - Calendar Model

private struct CalendarInfo: Codable {
  let title: String
  let accountName: String
  let isWritable: Bool
  let isDefault: Bool
}

private func mapCalendar(_ calendar: EKCalendar, defaultId: String?) -> CalendarInfo {
  CalendarInfo(
    title: calendar.title,
    accountName: calendar.source?.title ?? "Unknown",
    isWritable: calendar.allowsContentModifications,
    isDefault: calendar.calendarIdentifier == defaultId
  )
}

// MARK: - Calendar Tools

private struct ListCalendarsTool {
  let name = "list_calendars"

  func run(args: String) -> String {
    if let failure = calendarAccessFailure(CalendarManager.shared.ensureAccess()) {
      return failure
    }

    let store = CalendarManager.shared.store
    let defaultId = store.defaultCalendarForNewEvents?.calendarIdentifier
    let calendars = store.calendars(for: .event)
      .sorted {
        ($0.source?.title ?? "", $0.title) < ($1.source?.title ?? "", $1.title)
      }
      .map { mapCalendar($0, defaultId: defaultId) }

    return encodeJSON(calendars)
  }
}

private struct GetEventsTool {
  let name = "get_events"

  struct Args: Decodable {
    let limit: Int?
    let fromDate: String?
    let toDate: String?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected a JSON object")
    }

    if let failure = calendarAccessFailure(CalendarManager.shared.ensureAccess()) {
      return failure
    }

    let today = Date()
    let defaultEndDate = Calendar.current.date(byAdding: .day, value: 7, to: today)!

    var startDate = today
    if let fromDate = input.fromDate {
      guard let parsed = parseDate(fromDate) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'fromDate': \(fromDate)")
      }
      startDate = parsed
    }

    var endDate = defaultEndDate
    if let toDate = input.toDate {
      guard let parsed = parseDate(toDate) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'toDate': \(toDate)")
      }
      endDate = parsed
    }

    guard endDate >= startDate else {
      return Envelope.failure(.invalidArgs, "toDate must be on or after fromDate")
    }

    let limit: Int
    switch Validation.resolveLimit(input.limit, default: 10) {
    case .ok(let value): limit = value
    case .invalid(let message): return Envelope.failure(.invalidArgs, message)
    }

    let store = CalendarManager.shared.store
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)

    guard let allEvents = fetchEvents(store: store, predicate: predicate) else {
      return Envelope.failure(.timeout, "Calendar query timed out")
    }

    let eventModels =
      allEvents
      .sorted { $0.startDate < $1.startDate }
      .prefix(limit)
      .map(mapEvent)

    return encodeJSON(eventModels)
  }
}

private struct SearchEventsTool {
  let name = "search_events"

  struct Args: Decodable {
    let searchText: String
    let limit: Int?
    let fromDate: String?
    let toDate: String?
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected a JSON object")
    }

    guard !input.searchText.trimmingCharacters(in: .whitespaces).isEmpty else {
      return Envelope.failure(.invalidArgs, "Missing required field 'searchText'")
    }

    if let failure = calendarAccessFailure(CalendarManager.shared.ensureAccess()) {
      return failure
    }

    let today = Date()
    let defaultEndDate = Calendar.current.date(byAdding: .day, value: 30, to: today)!

    var startDate = today
    if let fromDate = input.fromDate {
      guard let parsed = parseDate(fromDate) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'fromDate': \(fromDate)")
      }
      startDate = parsed
    }

    var endDate = defaultEndDate
    if let toDate = input.toDate {
      guard let parsed = parseDate(toDate) else {
        return Envelope.failure(.invalidArgs, "Invalid date for field 'toDate': \(toDate)")
      }
      endDate = parsed
    }

    guard endDate >= startDate else {
      return Envelope.failure(.invalidArgs, "toDate must be on or after fromDate")
    }

    let searchText = input.searchText.lowercased()
    let limit: Int
    switch Validation.resolveLimit(input.limit, default: 10) {
    case .ok(let value): limit = value
    case .invalid(let message): return Envelope.failure(.invalidArgs, message)
    }

    let store = CalendarManager.shared.store
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)

    guard let allEvents = fetchEvents(store: store, predicate: predicate) else {
      return Envelope.failure(.timeout, "Calendar query timed out")
    }

    let eventModels =
      allEvents
      .filter { $0.title.lowercased().contains(searchText) }
      .sorted { $0.startDate < $1.startDate }
      .prefix(limit)
      .map(mapEvent)

    return encodeJSON(eventModels)
  }
}

private struct CreateEventTool {
  let name = "create_event"

  struct Args: Decodable {
    let title: String
    let startDate: String
    let endDate: String
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
  /// the default calendar), and an ambiguous name asks for `accountName`.
  private func resolveCalendar(store: EKEventStore, input: Args) -> Result<EKCalendar, String> {
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
              : "Account '\(accountName)' has multiple writable calendars. Specify 'calendarName': \(matches.map { $0.title }.joined(separator: ", "))"
          ))
      }
      guard let cal = store.defaultCalendarForNewEvents else {
        return .failure(
          Envelope.failure(
            .executionError,
            "No default calendar is configured. Specify 'calendarName' (use list_calendars to see available calendars).",
            retryable: false))
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
          "Calendar '\(calendarName)' not found\(scope). Use list_calendars to see available calendars."
        ))
    }

    let writable = matches.filter { $0.allowsContentModifications }
    guard !writable.isEmpty else {
      return .failure(
        Envelope.failure(
          .permissionDenied,
          "Calendar '\(calendarName)' is read-only. Use list_calendars to find a writable calendar."
        ))
    }

    guard writable.count == 1 else {
      let accounts = writable.map { $0.source?.title ?? "Unknown" }.joined(separator: ", ")
      return .failure(
        Envelope.failure(
          .invalidArgs,
          "Multiple calendars named '\(calendarName)' exist (accounts: \(accounts)). Specify 'accountName' to disambiguate."
        ))
    }

    return .success(writable[0])
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected a JSON object")
    }

    if let failure = calendarAccessFailure(CalendarManager.shared.ensureAccess()) {
      return failure
    }

    guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
      return Envelope.failure(.invalidArgs, "Missing required field 'title'")
    }

    guard let startDate = isoDateFormatter.date(from: input.startDate) else {
      return Envelope.failure(
        .invalidArgs,
        "Invalid date for field 'startDate': \(input.startDate). Use ISO format (YYYY-MM-DDTHH:mm:ssZ)")
    }

    guard let endDate = isoDateFormatter.date(from: input.endDate) else {
      return Envelope.failure(
        .invalidArgs,
        "Invalid date for field 'endDate': \(input.endDate). Use ISO format (YYYY-MM-DDTHH:mm:ssZ)")
    }

    guard endDate > startDate else {
      return Envelope.failure(.invalidArgs, "endDate must be after startDate")
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
      return
        "{\"success\": true, \"message\": \"Event \\\"\(escapeJSON(input.title))\\\" created in calendar \\\"\(escapeJSON(calendar.title))\\\" (\(escapeJSON(calendar.source?.title ?? "Unknown"))).\", \"eventId\": \"\(escapeJSON(event.eventIdentifier ?? ""))\"}"
    } catch {
      return Envelope.failure(.executionError, error.localizedDescription)
    }
  }
}

private struct OpenEventTool {
  let name = "open_event"

  struct Args: Decodable {
    let eventId: String
  }

  func run(args: String) -> String {
    guard let data = args.data(using: .utf8),
      let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
      return Envelope.failure(.invalidArgs, "Invalid arguments: expected a JSON object")
    }

    guard !input.eventId.trimmingCharacters(in: .whitespaces).isEmpty else {
      return Envelope.failure(.invalidArgs, "Missing required field 'eventId'")
    }

    if let failure = calendarAccessFailure(CalendarManager.shared.ensureAccess()) {
      return failure
    }

    let store = CalendarManager.shared.store
    guard let event = store.event(withIdentifier: input.eventId) else {
      return Envelope.failure(.notFound, "Event not found: \(input.eventId)")
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
      return "{\"success\": true, \"message\": \"Event opened successfully\"}"
    } else if result.timedOut {
      return Envelope.failure(.timeout, result.error)
    } else {
      return Envelope.failure(.executionError, result.error)
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

private func escapeJSON(_ str: String) -> String {
  return
    str
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
    .replacingOccurrences(of: "\r", with: "\\r")
    .replacingOccurrences(of: "\t", with: "\\t")
}

private func encodeJSON<T: Encodable>(_ value: T) -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = .prettyPrinted
  guard let data = try? encoder.encode(value),
    let json = String(data: data, encoding: .utf8)
  else {
    return "[]"
  }
  return json
}

// MARK: - C ABI Surface

private class PluginContext {
  let listCalendarsTool = ListCalendarsTool()
  let getEventsTool = GetEventsTool()
  let searchEventsTool = SearchEventsTool()
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
      return osrMakeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
    }

    switch id {
    case ctx.listCalendarsTool.name:
      return osrMakeCString(ctx.listCalendarsTool.run(args: payload))
    case ctx.getEventsTool.name:
      return osrMakeCString(ctx.getEventsTool.run(args: payload))
    case ctx.searchEventsTool.name:
      return osrMakeCString(ctx.searchEventsTool.run(args: payload))
    case ctx.createEventTool.name:
      return osrMakeCString(ctx.createEventTool.run(args: payload))
    case ctx.openEventTool.name:
      return osrMakeCString(ctx.openEventTool.run(args: payload))
    default:
      return osrMakeCString(Envelope.failure(.notFound, "Unknown tool: \(id)"))
    }
  }
)

/// File-scope manifest JSON embedded by the plugin. Referenced from `get_manifest`.
let calendarManifestJSON = """
      {
        "plugin_id": "osaurus.calendar",
        "name": "Calendar",
        "version": "1.2.0",
        "description": "A calendar plugin for macOS Calendar.app integration",
        "license": "MIT",
        "authors": ["Osaurus"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
            {
              "id": "list_calendars",
              "description": "List all calendars with their account name, writability, and which one is the default. Use this before create_event when the user has multiple accounts or the target calendar is ambiguous.",
              "parameters": {
                "type": "object",
                "properties": {},
                "required": []
              },
              "requirements": ["calendar"],
              "permission_policy": "auto"
            },
            {
              "id": "get_events",
              "widget": true,
              "description": "Get calendar events in a specified date range",
              "parameters": {
                "type": "object",
                "properties": {
                  "limit": {
                    "type": "integer",
                    "description": "Maximum number of events to return (default: 10)"
                  },
                  "fromDate": {
                    "type": "string",
                    "description": "Start date for search range in ISO format (default: today)"
                  },
                  "toDate": {
                    "type": "string",
                    "description": "End date for search range in ISO format (default: 7 days from now)"
                  }
                },
                "required": []
              },
              "requirements": ["calendar"],
              "permission_policy": "auto"
            },
            {
              "id": "search_events",
              "description": "Search for calendar events that match the search text",
              "parameters": {
                "type": "object",
                "properties": {
                  "searchText": {
                    "type": "string",
                    "description": "Text to search for in event titles"
                  },
                  "limit": {
                    "type": "integer",
                    "description": "Maximum number of events to return (default: 10)"
                  },
                  "fromDate": {
                    "type": "string",
                    "description": "Start date for search range in ISO format (default: today)"
                  },
                  "toDate": {
                    "type": "string",
                    "description": "End date for search range in ISO format (default: 30 days from now)"
                  }
                },
                "required": ["searchText"]
              },
              "requirements": ["calendar"],
              "permission_policy": "auto"
            },
            {
              "id": "create_event",
              "description": "Create a new calendar event",
              "parameters": {
                "type": "object",
                "properties": {
                  "title": {
                    "type": "string",
                    "description": "Title of the event"
                  },
                  "startDate": {
                    "type": "string",
                    "description": "Start date/time in ISO format (e.g., 2024-01-15T09:00:00Z)"
                  },
                  "endDate": {
                    "type": "string",
                    "description": "End date/time in ISO format (e.g., 2024-01-15T10:00:00Z)"
                  },
                  "location": {
                    "type": "string",
                    "description": "Location of the event"
                  },
                  "notes": {
                    "type": "string",
                    "description": "Notes/description for the event"
                  },
                  "isAllDay": {
                    "type": "boolean",
                    "description": "Whether this is an all-day event (default: false)"
                  },
                  "calendarName": {
                    "type": "string",
                    "description": "Name of the calendar to add the event to (default: the system default calendar). If the name exists in multiple accounts, also pass accountName."
                  },
                  "accountName": {
                    "type": "string",
                    "description": "Account (source) the calendar belongs to, e.g. 'iCloud' or 'Google'. Use list_calendars to see accounts."
                  }
                },
                "required": ["title", "startDate", "endDate"]
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
                  "eventId": {
                    "type": "string",
                    "description": "ID of the event to open"
                  }
                },
                "required": ["eventId"]
              },
              "requirements": ["calendar", "automation"],
              "permission_policy": "auto"
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
