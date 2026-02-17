# FastCheck Improvements Plan

## Overview
This document outlines the implementation plan for improvements 6, 7, and 8.

---

## 6. Scanner LiveView Improvements

### 6.1 Keyboard Shortcuts
**Priority**: High  
**Complexity**: Low  
**Files to Modify**:
- `lib/fastcheck_web/live/scanner_live.ex`
- `assets/js/app.js` (or create new scanner.js)

**Implementation**:
1. Add JavaScript event listeners for keyboard events
2. Map Enter key to trigger scan event
3. Map Tab key to toggle check-in direction
4. Prevent default browser behavior for these keys
5. Add visual feedback (highlight active button)

**Technical Details**:
- Use `phx-hook` for keyboard event handling
- Hook name: `KeyboardShortcuts`
- Events: `keydown` on document or scanner container
- Prevent default for Enter/Tab when scanner is active

**Testing**:
- Test Enter key triggers scan
- Test Tab key toggles direction
- Test shortcuts don't interfere with form inputs
- Test shortcuts work on mobile (should be disabled)

---

### 6.2 Sound Feedback
**Priority**: Medium  
**Complexity**: Low  
**Files to Modify**:
- `lib/fastcheck_web/live/scanner_live.ex`
- `assets/js/app.js` (or scanner.js)

**Implementation**:
1. Create audio feedback module in JavaScript
2. Play success sound (short beep) on successful scan
3. Play error sound (error tone) on failed scan
4. Use Web Audio API or HTML5 Audio
5. Add user preference toggle (enable/disable sounds)

**Technical Details**:
- Use `AudioContext` or `<audio>` elements
- Success sound: ~200ms, 800Hz tone
- Error sound: ~300ms, 400Hz descending tone
- Store preference in localStorage
- Respect browser autoplay policies

**Audio Files Needed**:
- `priv/static/audio/success.mp3` (or generate programmatically)
- `priv/static/audio/error.mp3` (or generate programmatically)

**Testing**:
- Test sounds play on success/error
- Test sounds don't play if disabled
- Test on different browsers
- Test volume levels

---

### 6.3 Scan History (Last 10 Scans)
**Priority**: Medium  
**Complexity**: Medium  
**Files to Modify**:
- `lib/fastcheck_web/live/scanner_live.ex`
- `lib/fastcheck/attendees/scan.ex` (or create new module)

**Implementation**:
1. Store last 10 scans in LiveView assigns
2. Display as a scrollable list below scanner
3. Show: ticket code, name, time, status (success/error)
4. Click to re-scan or view details
5. Clear history button

**Technical Details**:
- Use LiveView assigns: `scan_history: []`
- Max 10 items, FIFO queue
- Format: `%{ticket_code, name, scanned_at, status, message}`
- Update on every scan (success or error)
- Use `phx-update="stream"` for efficient updates

**UI Design**:
- Collapsible panel below scanner
- Show last scan prominently
- Color code: green (success), red (error)
- Timestamp relative (e.g., "2 seconds ago")

**Testing**:
- Test history updates on scan
- Test history limits to 10 items
- Test history persists during session
- Test clear history functionality

---

### 6.4 Bulk Manual Entry Mode
**Priority**: Low  
**Complexity**: High  
**Files to Modify**:
- `lib/fastcheck_web/live/scanner_live.ex`
- `lib/fastcheck/attendees/scan.ex`
- Create: `lib/fastcheck_web/live/bulk_entry_live.ex` (optional separate view)

**Implementation**:
1. Add "Bulk Entry" mode toggle
2. Multi-line textarea for ticket codes (one per line)
3. Process all codes on "Process" button
4. Show results: success count, error count, details
5. Export results option

**Technical Details**:
- Parse textarea input (split by newline)
- Process codes sequentially or in batch
- Use `bulk_check_in/2` function
- Show progress indicator
- Display results table

**UI Design**:
- Toggle between "Single Scan" and "Bulk Entry" modes
- Large textarea (10-20 lines)
- Process button with loading state
- Results table with status per code
- Copy results button

**Testing**:
- Test bulk processing of 10+ codes
- Test error handling for invalid codes
- Test progress indicator
- Test results display

---

## 7. Dashboard Enhancements

### 7.1 Event Editing
**Priority**: High  
**Complexity**: Medium  
**Files to Modify**:
- `lib/fastcheck_web/live/dashboard_live.ex`
- `lib/fastcheck/events.ex`
- `lib/fastcheck/events/event.ex`

**Implementation**:
1. Add "Edit" button to each event card
2. Show edit form (similar to create form)
3. Pre-populate with existing values
4. Update event via `Events.update_event/2`
5. Validate API key if changed
6. Show success/error messages

**Technical Details**:
- New LiveView event: `"edit_event"`
- New function: `Events.update_event/2`
- Reuse existing form components
- Validate API key only if changed
- Update cache after edit

**UI Design**:
- Edit button on event card
- Modal or inline form
- Show "Cancel" and "Save" buttons
- Disable edit during sync

**Testing**:
- Test editing event name, location, entrance
- Test updating API key (with validation)
- Test canceling edit
- Test error handling

---

### 7.2 Event Archiving/Unarchiving UI
**Priority**: Medium  
**Complexity**: Low  
**Files to Modify**:
- `lib/fastcheck_web/live/dashboard_live.ex`
- `lib/fastcheck/events.ex`

**Implementation**:
1. Add "Archive" button to active events
2. Add "Unarchive" button to archived events
3. Update event status to "archived" or "active"
4. Filter events list (show archived separately or hide)
5. Confirm dialog before archiving

**Technical Details**:
- New LiveView events: `"archive_event"`, `"unarchive_event"`
- New function: `Events.archive_event/1`, `Events.unarchive_event/1`
- Update `event_lifecycle_state/2` logic
- Prevent archiving during sync

**UI Design**:
- Archive button (red) on active events
- Unarchive button (green) on archived events
- Confirmation modal: "Archive this event? Archived events cannot be synced or scanned."
- Visual indicator for archived events (grayed out)

**Testing**:
- Test archiving active event
- Test unarchiving archived event
- Test archived events don't show sync button
- Test archived events don't show scanner link

---

### 7.3 Export Functionality (CSV/Excel)
**Priority**: High  
**Complexity**: Medium  
**Files to Create/Modify**:
- `lib/fastcheck_web/controllers/export_controller.ex` (new)
- `lib/fastcheck_web/live/dashboard_live.ex`
- `lib/fastcheck/attendees.ex` (add export functions)
- Add dependency: `nimble_csv` or `csvlixir`

**Implementation**:
1. Add "Export" button to event card
2. Export options: Attendees CSV, Check-ins CSV, Excel (optional)
3. Generate CSV with proper headers
4. Stream large exports to prevent memory issues
5. Download via browser

**Export Formats**:

**Attendees CSV**:
```csv
Ticket Code,First Name,Last Name,Email,Ticket Type,Payment Status,Checked In At,Check-ins Remaining
25955-1,John,Smith,john@example.com,VIP,paid,2025-11-13 19:00:00,0
```

**Check-ins CSV**:
```csv
Ticket Code,Attendee Name,Scanned At,Entrance,Operator,Status
25955-1,John Smith,2025-11-13 19:00:00,Main Gate,Scanner 1,success
```

**Technical Details**:
- Use `NimbleCSV` or `CSV` library
- Stream exports for large datasets (>1000 rows)
- Set proper Content-Type headers
- Use `send_download/3` for file download
- Add date range filter (optional)

**UI Design**:
- Export dropdown menu on event card
- Options: "Export Attendees (CSV)", "Export Check-ins (CSV)"
- Loading indicator during export
- Success message with download link

**Testing**:
- Test CSV export for 100+ attendees
- Test CSV export for 1000+ check-ins
- Test CSV format is correct
- Test download works in different browsers

---

### 7.4 Search/Filter for Events List
**Priority**: Medium  
**Complexity**: Low  
**Files to Modify**:
- `lib/fastcheck_web/live/dashboard_live.ex`
- `lib/fastcheck/events/cache.ex` (optional optimization)

**Implementation**:
1. Add search input above events list
2. Filter events by name, location, status
3. Real-time filtering (debounced)
4. Show "No events found" message
5. Clear search button

**Technical Details**:
- Use `phx-debounce="300"` on input
- Filter in LiveView assigns
- Case-insensitive search
- Search across: name, location, entrance_name

**UI Design**:
- Search bar with icon
- Placeholder: "Search events..."
- Clear button (X) when search active
- Highlight matching text (optional)

**Testing**:
- Test search by name
- Test search by location
- Test search clears correctly
- Test search with no results

---

## 8. Sync Progress Improvements

### 8.1 Estimated Time Remaining
**Priority**: Medium  
**Complexity**: Medium  
**Files to Modify**:
- `lib/fastcheck/events/sync.ex`
- `lib/fastcheck_web/live/dashboard_live.ex`

**Implementation**:
1. Track sync start time and pages processed
2. Calculate average time per page
3. Estimate remaining pages * average time
4. Display: "Estimated time remaining: 2 minutes"
5. Update estimate as sync progresses

**Technical Details**:
- Store sync metadata: `%{started_at, pages_processed, total_pages, avg_time_per_page}`
- Calculate: `(total_pages - pages_processed) * avg_time_per_page`
- Update estimate every 5 pages
- Handle edge cases (first page, last page)

**UI Design**:
- Show below progress bar
- Format: "Estimated time remaining: 2m 30s"
- Update dynamically
- Show "Calculating..." for first few pages

**Testing**:
- Test estimate calculation
- Test estimate updates during sync
- Test estimate accuracy
- Test edge cases (1 page, many pages)

---

### 8.2 Pause/Resume for Long Syncs
**Priority**: Low  
**Complexity**: High  
**Files to Modify**:
- `lib/fastcheck/events/sync.ex`
- `lib/fastcheck_web/live/dashboard_live.ex`
- Create: `lib/fastcheck/events/sync_state.ex` (new)

**Implementation**:
1. Store sync state in GenServer or database
2. Add "Pause" button during sync
3. Save current page and state
4. Add "Resume" button for paused syncs
5. Continue from saved page

**Technical Details**:
- Use GenServer to manage sync state
- Store: `%{event_id, current_page, total_pages, status: :paused}`
- Check pause flag in sync loop
- Resume from saved page
- Clean up state on completion/error

**UI Design**:
- Pause button replaces "Sync" button during sync
- Resume button for paused events
- Show "Paused" status badge
- Confirmation before pausing

**Testing**:
- Test pausing sync mid-way
- Test resuming paused sync
- Test pause state persists
- Test cleanup on completion

---

### 8.3 Sync History/Audit Log
**Priority**: Medium  
**Complexity**: Medium  
**Files to Create/Modify**:
- Create: `lib/fastcheck/events/sync_log.ex` (schema)
- Create: `priv/repo/migrations/XXXXXX_create_sync_logs.exs`
- `lib/fastcheck/events/sync.ex`
- `lib/fastcheck_web/live/dashboard_live.ex`

**Implementation**:
1. Create `sync_logs` table
2. Log every sync attempt (start, progress, completion, error)
3. Show sync history on event card
4. Display: date, time, status, attendees synced, duration

**Database Schema**:
```sql
CREATE TABLE sync_logs (
  id SERIAL PRIMARY KEY,
  event_id INTEGER REFERENCES events(id),
  started_at TIMESTAMP NOT NULL,
  completed_at TIMESTAMP,
  status VARCHAR(50), -- 'completed', 'failed', 'paused', 'cancelled'
  attendees_synced INTEGER DEFAULT 0,
  total_pages INTEGER,
  pages_processed INTEGER,
  error_message TEXT,
  duration_ms INTEGER,
  inserted_at TIMESTAMP DEFAULT NOW()
);
```

**Technical Details**:
- Log sync start in `sync_event/2`
- Log progress updates
- Log completion/error
- Query recent logs for event
- Display last 5 syncs

**UI Design**:
- "Sync History" link on event card
- Modal or expandable section
- Table with columns: Date, Status, Attendees, Duration
- Click to view details

**Testing**:
- Test logging sync start
- Test logging sync completion
- Test logging sync errors
- Test querying sync history

---

### 8.4 Incremental Sync Option
**Priority**: Medium  
**Complexity**: High  
**Files to Modify**:
- `lib/fastcheck/events/sync.ex`
- `lib/fastcheck/tickera_client.ex`
- `lib/fastcheck_web/live/dashboard_live.ex`

**Implementation**:
1. Store `last_sync_at` timestamp per event
2. Add "Incremental Sync" button
3. Pass `since` parameter to Tickera API
4. Only fetch attendees updated since last sync
5. Update existing attendees, insert new ones

**Technical Details**:
- Use `last_sync_at` from event record
- Format as ISO 8601 for Tickera API
- Tickera API: `/tickets_info/{per_page}/{page}/?since={timestamp}`
- Merge with existing attendees (update or insert)
- Update `last_sync_at` after successful sync

**UI Design**:
- "Full Sync" button (existing)
- "Incremental Sync" button (new)
- Show last sync time
- Tooltip: "Only syncs changes since last sync"

**Testing**:
- Test incremental sync fetches only changes
- Test incremental sync updates existing attendees
- Test incremental sync inserts new attendees
- Test incremental sync handles API errors

---

## Implementation Order

### Phase 1: Quick Wins (Week 1)
1. ✅ Scanner keyboard shortcuts (6.1)
2. ✅ Dashboard search/filter (7.4)
3. ✅ Event archiving UI (7.2)

### Phase 2: High Value (Week 2)
4. ✅ Event editing (7.1)
5. ✅ Export functionality (7.3)
6. ✅ Scan history (6.3)

### Phase 3: Advanced Features (Week 3)
7. ✅ Sound feedback (6.2)
8. ✅ Estimated time remaining (8.1)
9. ✅ Sync history/audit log (8.3)

### Phase 4: Complex Features (Week 4)
10. ✅ Bulk manual entry (6.4)
11. ✅ Incremental sync (8.4)
12. ✅ Pause/resume sync (8.2)

---

## Dependencies

### New Dependencies Needed:
- `nimble_csv` - For CSV export (or use built-in CSV)
- `timex` - For time calculations (optional, can use DateTime)

### Database Migrations:
- `sync_logs` table for sync history

---

## Testing Strategy

### Unit Tests:
- Test keyboard shortcut handlers
- Test export CSV generation
- Test sync time estimation
- Test incremental sync logic

### Integration Tests:
- Test event editing flow
- Test export download
- Test sync history logging
- Test pause/resume sync

### Manual Testing:
- Test keyboard shortcuts in browser
- Test sound feedback
- Test bulk entry with 50+ codes
- Test export with 1000+ records

---

## Notes

- All features should maintain backward compatibility
- Consider mobile responsiveness for all UI changes
- Add proper error handling and user feedback
- Update documentation as features are added
- Consider performance impact of new features
