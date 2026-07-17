import EventKit
import Foundation

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

// MARK: - Calendar Tools

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
    let event = EKEvent(eventStore: store)

    event.title = input.title
    event.startDate = startDate
    event.endDate = endDate
    event.location = input.location
    event.notes = input.notes
    event.isAllDay = input.isAllDay ?? false

    // Use the specified calendar, falling back to default if not found
    if let calendarName = input.calendarName,
      let cal = store.calendars(for: .event).first(where: { $0.title == calendarName })
    {
      event.calendar = cal
    } else {
      event.calendar = store.defaultCalendarForNewEvents
    }

    do {
      try store.save(event, span: .thisEvent)
      return
        "{\"success\": true, \"message\": \"Event \\\"\(escapeJSON(input.title))\\\" created successfully.\", \"eventId\": \"\(escapeJSON(event.eventIdentifier))\"}"
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

private let maxCapturedOutputBytes = 5 * 1024 * 1024

/// Runs an AppleScript via /usr/bin/osascript in a separate process with a timeout.
/// Thread-safe (unlike NSAppleScript). Streams are drained concurrently so large
/// output cannot deadlock the pipe; on timeout the process is terminated and then
/// killed after a grace period.
private func runAppleScript(_ source: String, timeout: TimeInterval = 15) -> (
  success: Bool, timedOut: Bool, output: String, error: String
) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
  process.arguments = ["-e", source]

  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe

  let lock = NSLock()
  var outData = Data()
  var errData = Data()

  outPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    lock.lock()
    if outData.count < maxCapturedOutputBytes { outData.append(chunk) }
    lock.unlock()
  }
  errPipe.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    lock.lock()
    if errData.count < maxCapturedOutputBytes { errData.append(chunk) }
    lock.unlock()
  }

  do {
    try process.run()
  } catch {
    outPipe.fileHandleForReading.readabilityHandler = nil
    errPipe.fileHandleForReading.readabilityHandler = nil
    return (false, false, "", error.localizedDescription)
  }

  let timedOutFlag = NSLock()
  var timedOut = false

  let timer = DispatchSource.makeTimerSource(queue: .global())
  timer.schedule(deadline: .now() + timeout)
  timer.setEventHandler {
    timedOutFlag.lock()
    timedOut = true
    timedOutFlag.unlock()
    if process.isRunning { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
  }
  timer.resume()

  process.waitUntilExit()
  timer.cancel()

  outPipe.fileHandleForReading.readabilityHandler = nil
  errPipe.fileHandleForReading.readabilityHandler = nil

  timedOutFlag.lock()
  let didTimeOut = timedOut
  timedOutFlag.unlock()

  lock.lock()
  let output =
    String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  let errOutput =
    String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  lock.unlock()

  return (
    process.terminationStatus == 0 && !didTimeOut,
    didTimeOut,
    output,
    didTimeOut ? "AppleScript timed out after \(Int(timeout)) seconds" : errOutput
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

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
  @convention(c) (
    osr_plugin_ctx_t?,
    UnsafePointer<CChar>?,  // type
    UnsafePointer<CChar>?,  // id
    UnsafePointer<CChar>?  // payload
  ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
  var free_string: osr_free_string_t?
  var `init`: osr_init_t?
  var destroy: osr_destroy_t?
  var get_manifest: osr_get_manifest_t?
  var invoke: osr_invoke_t?
}

private class PluginContext {
  let getEventsTool = GetEventsTool()
  let searchEventsTool = SearchEventsTool()
  let createEventTool = CreateEventTool()
  let openEventTool = OpenEventTool()
}

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

private var api: osr_plugin_api = {
  var api = osr_plugin_api()

  api.free_string = { ptr in
    if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
  }

  api.`init` = {
    let ctx = PluginContext()
    return Unmanaged.passRetained(ctx).toOpaque()
  }

  api.destroy = { ctxPtr in
    guard let ctxPtr = ctxPtr else { return }
    Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
  }

  api.get_manifest = { ctxPtr in
    return makeCString(calendarManifestJSON)
  }

  api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
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
      return makeCString(Envelope.failure(.invalidArgs, "Unknown capability type: \(type)"))
    }

    switch id {
    case ctx.getEventsTool.name:
      return makeCString(ctx.getEventsTool.run(args: payload))
    case ctx.searchEventsTool.name:
      return makeCString(ctx.searchEventsTool.run(args: payload))
    case ctx.createEventTool.name:
      return makeCString(ctx.createEventTool.run(args: payload))
    case ctx.openEventTool.name:
      return makeCString(ctx.openEventTool.run(args: payload))
    default:
      return makeCString(Envelope.failure(.notFound, "Unknown tool: \(id)"))
    }
  }

  return api
}()

/// File-scope manifest JSON embedded by the plugin. Referenced from `get_manifest`.
let calendarManifestJSON = """
      {
        "plugin_id": "osaurus.calendar",
        "name": "Calendar",
        "version": "1.0.5",
        "description": "A calendar plugin for macOS Calendar.app integration",
        "license": "MIT",
        "authors": ["Osaurus"],
        "min_macos": "13.0",
        "min_osaurus": "0.5.0",
        "capabilities": {
          "tools": [
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
                    "description": "Name of the calendar to add the event to (default: uses first calendar)"
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

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
