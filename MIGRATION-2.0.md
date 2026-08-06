# Calendar 2.0 Migration

Calendar 2.0 adopts the canonical Osaurus tool contract and is a breaking release.

## Tool changes

- `get_events` and `search_events` are replaced by `query_events`.
- `query_events.query` is optional. Omit it to list events; provide it for a case-insensitive title search.
- Date-range arguments are now `range_start` and `range_end` and require RFC 3339 timestamps.
- All arguments and result fields use snake_case. In particular, event creation uses `start_at`, `end_at`, `is_all_day`, `calendar_name`, and `account_name`; opening uses `event_id`.
- `list_calendars`, `query_events`, `create_event`, and `open_event` are the only tools.

## Result changes

Every call now returns a canonical envelope:

```json
{"ok":true,"tool":"query_events","result":{}}
```

Failures use the host's canonical kinds and retry policy. Collection results report `returned_count`, `total_count`, and `truncated`. Calendar and event records include stable IDs and `account_name`; timestamps are RFC 3339. `create_event` returns the complete created event.

## Permission changes

Read-only `list_calendars` and `query_events` remain automatic. `create_event` and `open_event` both require confirmation because they persist a change or activate Calendar.app.
