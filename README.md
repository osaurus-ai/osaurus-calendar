# osaurus-calendar

An Osaurus plugin for interacting with macOS Calendar.app via **EventKit** (native framework) and AppleScript (for UI control).

Version 2.0 exposes four strict, snake_case tools and returns canonical Osaurus envelopes. EventKit handles calendar reads and event creation; AppleScript is used only to open an event in Calendar.app.

## Prerequisites

**Permissions are required.** The application using this plugin (e.g., Osaurus) requires two distinct permissions:

1.  **Calendars Access** (Full Access):

    - **Why**: Required for `list_calendars`, `query_events`, `create_event`, and `open_event`.
    - **How**: System Settings > Privacy & Security > Calendars > Toggle **ON** for your app.
    - _Host App Requirement_: `Info.plist` must include `NSCalendarsFullAccessUsageDescription` (macOS 14+) or `NSCalendarsUsageDescription`.

2.  **Automation** (Apple Events):
    - **Why**: Required only for `open_event` to control the Calendar app UI.
    - **How**: System Settings > Privacy & Security > Automation > Expand your app > Toggle **ON** for "Calendar".
    - _Host App Requirement_: `Info.plist` must include `NSAppleEventsUsageDescription`.

## Tools

### `list_calendars`

List all calendars with their account name, writability, and which one is the default. Useful when multiple accounts are configured (e.g. iCloud + Google) and calendar names are duplicated across accounts.

**Parameters:** none

**Example response:**

```json
{
  "ok": true,
  "tool": "list_calendars",
  "result": {
    "calendars": [
      {
        "calendar_id": "opaque-calendar-id",
        "calendar_name": "Work",
        "account_name": "iCloud",
        "is_writable": true,
        "is_default": true
      }
    ],
    "returned_count": 1,
    "total_count": 1,
    "truncated": false
  }
}
```

### `query_events`

List events in an RFC 3339 range, optionally filtering event titles with a case-insensitive query.

**Parameters:**

- `query` (optional): Non-empty title substring
- `limit` (optional): Maximum results, from 1 through 200 (default: 50)
- `range_start` (optional): RFC 3339 range start (default: current time)
- `range_end` (optional): RFC 3339 range end (default: seven days from now)

**Example:**

```json
{
  "query": "meeting",
  "limit": 10,
  "range_start": "2026-08-06T00:00:00-07:00",
  "range_end": "2026-08-13T00:00:00-07:00"
}
```

### `create_event`

Create a new calendar event.

**Parameters:**

- `title` (required): Title of the event
- `start_at` (required): Start date/time as an RFC 3339 timestamp
- `end_at` (required): End date/time as an RFC 3339 timestamp after `start_at`
- `location` (optional): Location of the event
- `notes` (optional): Notes/description for the event
- `is_all_day` (optional): Whether this is an all-day event (default: false)
- `calendar_name` (optional): Calendar name (default: the system default calendar)
- `account_name` (optional): Account returned by `list_calendars`; use it when calendar names are duplicated

**Example:**

```json
{
  "title": "Team Standup",
  "start_at": "2026-08-06T09:00:00-07:00",
  "end_at": "2026-08-06T09:30:00-07:00",
  "location": "Conference Room A",
  "notes": "Daily sync meeting",
  "calendar_name": "Work",
  "account_name": "iCloud"
}
```

### `open_event`

Open a specific calendar event in the Calendar app.

**Parameters:**

- `event_id` (required): Stable ID obtained from `query_events` or `create_event`

**Example:**

```json
{
  "event_id": "ABC123-DEF456-GHI789"
}
```

## Development

1. Build:

   ```bash
   swift build -c release
   cp .build/release/libosaurus-calendar.dylib ./libosaurus-calendar.dylib
   ```

2. Install locally:
   ```bash
   osaurus tools install .
   ```

## Publishing

### Code Signing (Required for Distribution)

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  .build/release/libosaurus-calendar.dylib
```

### Package and Distribute

```bash
osaurus tools package osaurus.calendar 2.0.0
```

This creates `osaurus.calendar-2.0.0.zip` for distribution.

## Response Format

### Event List Response

`query_events` returns a canonical envelope. Event timestamps use RFC 3339 with the user's local UTC offset.

```json
{
  "ok": true,
  "tool": "query_events",
  "result": {
    "events": [
      {
        "event_id": "unique-event-id",
        "title": "Event Title",
        "location": "Event Location",
        "notes": "Event notes/description",
        "start_at": "2026-08-06T09:00:00-07:00",
        "end_at": "2026-08-06T10:00:00-07:00",
        "calendar_id": "opaque-calendar-id",
        "calendar_name": "Work",
        "account_name": "iCloud",
        "is_all_day": false,
        "url": "https://example.com"
      }
    ],
    "returned_count": 1,
    "total_count": 1,
    "truncated": false,
    "range_start": "2026-08-06T00:00:00-07:00",
    "range_end": "2026-08-13T00:00:00-07:00"
  }
}
```

### Create Event Response

`create_event` returns the complete created event using the same event shape.

```json
{
  "ok": true,
  "tool": "create_event",
  "result": {
    "event_id": "ABC123-DEF456-GHI789",
    "title": "Team Standup",
    "start_at": "2026-08-06T09:00:00-07:00",
    "end_at": "2026-08-06T09:30:00-07:00",
    "calendar_id": "opaque-calendar-id",
    "calendar_name": "Work",
    "account_name": "iCloud",
    "is_all_day": false
  }
}
```
