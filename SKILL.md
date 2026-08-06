---
name: osaurus-calendar
description: Use when the user asks to inspect calendars, find events, create an event, or open an event in macOS Calendar.
---

# Calendar

Use `list_calendars` before creating an event when the target calendar is unclear. Calendar names can repeat across accounts, so pass both `calendar_name` and the returned `account_name` when needed.

Use `query_events` for both browsing and title search. Set explicit RFC 3339 `range_start` and `range_end` values for the period the user requested, and pass `query` only when filtering event titles. If `truncated` is true, narrow the range or raise `limit` within its bound.

Treat `event_id` and `calendar_id` as opaque stable identifiers. Pass them through unchanged.

`create_event` changes the user's calendar and requires confirmation. Verify the title, times, time-zone offsets, all-day status, and target calendar first. `open_event` activates Calendar.app and also requires confirmation.

Calendar access is required for every tool. Automation permission is additionally required to open an event.
