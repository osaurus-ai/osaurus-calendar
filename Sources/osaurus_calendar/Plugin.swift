import Cocoa
import EventKit
import Foundation

// MARK: - EventKit Helper

private class CalendarManager {
  static let shared = CalendarManager()
  let store = EKEventStore()

  private init() {}

  func ensureAccess() -> Bool {
    let status = EKEventStore.authorizationStatus(for: .event)

    switch status {
    case .authorized, .fullAccess:
      return true
    case .notDetermined:
      return requestAccess()
    case .denied, .restricted, .writeOnly:
      return false
    @unknown default:
      return false
    }
  }

  private func requestAccess() -> Bool {
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

    _ = semaphore.wait(timeout: .now() + 60)  // 60s timeout for user interaction
    return granted
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
      return "{\"error\": \"Invalid arguments\"}"
    }

    guard CalendarManager.shared.ensureAccess() else {
      return "{\"error\": \"Calendar access denied\"}"
    }

    let limit = input.limit ?? 10
    let today = Date()
    let calendar = Calendar.current
    let defaultEndDate = calendar.date(byAdding: .day, value: 7, to: today)!

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [
      .withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
    ]

    let simpleDateFormatter = DateFormatter()
    simpleDateFormatter.dateFormat = "yyyy-MM-dd"

    func parseDate(_ str: String) -> Date? {
      if let date = dateFormatter.date(from: str) { return date }
      if let date = simpleDateFormatter.date(from: str) { return date }
      return nil
    }

    let startDate = input.fromDate.flatMap(parseDate) ?? today
    let endDate = input.toDate.flatMap(parseDate) ?? defaultEndDate

    let store = CalendarManager.shared.store
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
    let events = store.events(matching: predicate)
      .sorted { $0.startDate < $1.startDate }
      .prefix(limit)

    let eventModels = events.map { event in
      CalendarEvent(
        id: event.eventIdentifier,
        title: event.title,
        location: event.location,
        notes: event.notes,
        startDate: dateFormatter.string(from: event.startDate),
        endDate: dateFormatter.string(from: event.endDate),
        calendarName: event.calendar.title,
        isAllDay: event.isAllDay,
        url: event.url?.absoluteString
      )
    }

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
      return "{\"error\": \"Invalid arguments\"}"
    }

    guard CalendarManager.shared.ensureAccess() else {
      return "{\"error\": \"Calendar access denied\"}"
    }

    let limit = input.limit ?? 10
    let today = Date()
    let calendar = Calendar.current
    let defaultEndDate = calendar.date(byAdding: .day, value: 30, to: today)!

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [
      .withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
    ]

    let simpleDateFormatter = DateFormatter()
    simpleDateFormatter.dateFormat = "yyyy-MM-dd"

    func parseDate(_ str: String) -> Date? {
      if let date = dateFormatter.date(from: str) { return date }
      if let date = simpleDateFormatter.date(from: str) { return date }
      return nil
    }

    let startDate = input.fromDate.flatMap(parseDate) ?? today
    let endDate = input.toDate.flatMap(parseDate) ?? defaultEndDate
    let searchText = input.searchText.lowercased()

    let store = CalendarManager.shared.store
    let predicate = store.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
    let events = store.events(matching: predicate)
      .filter { $0.title.lowercased().contains(searchText) }
      .sorted { $0.startDate < $1.startDate }
      .prefix(limit)

    let eventModels = events.map { event in
      CalendarEvent(
        id: event.eventIdentifier,
        title: event.title,
        location: event.location,
        notes: event.notes,
        startDate: dateFormatter.string(from: event.startDate),
        endDate: dateFormatter.string(from: event.endDate),
        calendarName: event.calendar.title,
        isAllDay: event.isAllDay,
        url: event.url?.absoluteString
      )
    }

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
      return "{\"error\": \"Invalid arguments\"}"
    }

    guard CalendarManager.shared.ensureAccess() else {
      return "{\"success\": false, \"message\": \"Calendar access denied\"}"
    }

    guard !input.title.trimmingCharacters(in: .whitespaces).isEmpty else {
      return "{\"success\": false, \"message\": \"Event title cannot be empty\"}"
    }

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [
      .withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime,
    ]

    guard let startDate = dateFormatter.date(from: input.startDate),
      let endDate = dateFormatter.date(from: input.endDate)
    else {
      return
        "{\"success\": false, \"message\": \"Invalid date format. Please use ISO format (YYYY-MM-DDTHH:mm:ssZ)\"}"
    }

    guard endDate > startDate else {
      return "{\"success\": false, \"message\": \"End date must be after start date\"}"
    }

    let store = CalendarManager.shared.store
    let event = EKEvent(eventStore: store)

    event.title = input.title
    event.startDate = startDate
    event.endDate = endDate
    event.location = input.location
    event.notes = input.notes
    event.isAllDay = input.isAllDay ?? false

    // Find calendar
    if let calendarName = input.calendarName {
      if let cal = store.calendars(for: .event).first(where: { $0.title == calendarName }) {
        event.calendar = cal
      } else {
        // Fallback to default if specified not found? Or fail?
        // Using default is safer for "success"
        event.calendar = store.defaultCalendarForNewEvents
      }
    } else {
      event.calendar = store.defaultCalendarForNewEvents
    }

    do {
      try store.save(event, span: .thisEvent)
      return
        "{\"success\": true, \"message\": \"Event \\\"\(escapeJSON(input.title))\\\" created successfully.\", \"eventId\": \"\(escapeJSON(event.eventIdentifier))\"}"
    } catch {
      return "{\"success\": false, \"message\": \"\(escapeJSON(error.localizedDescription))\"}"
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
      return "{\"error\": \"Invalid arguments\"}"
    }

    guard CalendarManager.shared.ensureAccess() else {
      return "{\"success\": false, \"message\": \"Calendar access denied\"}"
    }

    let store = CalendarManager.shared.store
    guard let event = store.event(withIdentifier: input.eventId) else {
      return "{\"success\": false, \"message\": \"Event not found\"}"
    }

    // Use AppleScript to open the specific event
    // We can target the event by UID

    // Format date for AppleScript
    let appleScriptDateFormatter = DateFormatter()
    appleScriptDateFormatter.dateStyle = .full
    appleScriptDateFormatter.timeStyle = .medium
    let dateString = appleScriptDateFormatter.string(from: event.startDate)

    let eventId = event.eventIdentifier ?? input.eventId

    let script = """
      tell application "Calendar"
          activate
          set found to false
          repeat with cal in calendars
              if name of cal is "\(event.calendar.title)" then
                  try
                      set evt to (first event of cal whose uid is "\(eventId)")
                      show evt
                      set found to true
                      exit repeat
                  end try
              end if
          end repeat
          if not found then
              -- Fallback: switch to date
              switch view to day view
              view calendar date (date "\(dateString)")
          end if
      end tell
      """

    // Simple AppleScript runner
    var error: NSDictionary?
    let appleScript = NSAppleScript(source: script)
    if appleScript?.executeAndReturnError(&error) != nil {
      return "{\"success\": true, \"message\": \"Event opened successfully\"}"
    } else {
      let msg = error?[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
      return "{\"success\": false, \"message\": \"\(escapeJSON(msg))\"}"
    }
  }
}

// MARK: - Helper Functions

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

// MARK: - C ABI surface

// Opaque context
private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer

// Function pointers
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

// Context state (simple wrapper class to hold state)
private class PluginContext {
  let getEventsTool = GetEventsTool()
  let searchEventsTool = SearchEventsTool()
  let createEventTool = CreateEventTool()
  let openEventTool = OpenEventTool()
}

// Helper to return C strings
private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
  guard let ptr = strdup(s) else { return nil }
  return UnsafePointer(ptr)
}

// API Implementation
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
    // Manifest JSON matching new spec
    let manifest = """
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
    return makeCString(manifest)
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
      return makeCString("{\"error\": \"Unknown capability type\"}")
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
      return makeCString("{\"error\": \"Unknown tool: \(id)\"}")
    }
  }

  return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
  return UnsafeRawPointer(&api)
}
