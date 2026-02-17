# Integration Test Setup

## Overview

A comprehensive end-to-end integration test has been created to test the entire FastCheck flow:

1. **Create event** with Tickera credentials
2. **Mock Tickera API** responses using Bypass
3. **Sync attendees** from Tickera API
4. **Scan tickets** via LiveView scanner
5. **Verify check-ins** are recorded correctly
6. **Test incremental sync** functionality
7. **Test export** functionality (CSV)

## Files Created

### 1. `test/support/fixtures.ex`
Helper module providing:
- `create_event/1` - Creates test events with encrypted API keys
- `create_attendee/2` - Creates test attendees for events
- `mock_event_essentials_response/0` - Mock Tickera event essentials
- `mock_tickets_info_response/3` - Mock Tickera tickets list
- `mock_check_credentials_response/1` - Mock Tickera credentials check

### 2. `test/fastcheck/integration/end_to_end_test.exs`
Main integration test file with:
- Full end-to-end flow test
- Error handling test
- Bulk entry mode test

## Dependencies Added

- **Bypass** (`~> 2.1`) - HTTP request mocking library for testing

## Running the Tests

### Prerequisites
1. Ensure PostgreSQL is running and accessible
2. Database credentials must be configured in `config/test.exs`
3. Run migrations: `MIX_ENV=test mix ecto.migrate`

### Run All Integration Tests
```bash
mix test test/fastcheck/integration/
```

### Run Specific Test
```bash
mix test test/fastcheck/integration/end_to_end_test.exs
```

### Run with Trace (verbose output)
```bash
mix test test/fastcheck/integration/end_to_end_test.exs --trace
```

## Test Flow

### Main Test: "creates event, syncs attendees, scans tickets, and verifies results"

1. **Setup**: Creates Bypass server and test event
2. **Step 1**: Verifies event was created
3. **Step 2**: Syncs attendees from mocked Tickera API
4. **Step 3**: Tests scanning via LiveView scanner
5. **Step 4**: Verifies stats are updated
6. **Step 5**: Tests duplicate scan prevention
7. **Step 6**: Tests incremental sync
8. **Step 7**: Tests CSV export functionality

### Error Handling Test
- Simulates API failures
- Verifies error states are handled gracefully

### Bulk Entry Test
- Tests bulk manual entry mode
- Verifies multiple tickets can be processed

## Mock Data

The test uses realistic mock data:
- **50 attendees** by default
- Ticket codes: `TICKET-1`, `TICKET-2`, etc.
- Names: `Attendee1 Test1`, `Attendee2 Test2`, etc.
- Emails: `attendee1@example.com`, `attendee2@example.com`, etc.

## Customization

### Adjust Number of Attendees
In `test/fastcheck/integration/end_to_end_test.exs`, modify:
```elixir
response = mock_tickets_info_response(1, 100, 50)  # Change 50 to desired count
```

### Add More Test Scenarios
Add new test cases in the `describe "Full end-to-end flow"` block:
```elixir
test "your test name", %{conn: conn, event: event, bypass: bypass, api_key: api_key} do
  # Your test code
end
```

## Troubleshooting

### Database Connection Errors
- Verify PostgreSQL is running: `pg_isready`
- Check `config/test.exs` for correct database credentials
- Ensure test database exists: `MIX_ENV=test mix ecto.create`

### Bypass Port Conflicts
- Bypass automatically selects available ports
- If issues occur, ensure no other services are using the port range

### Test Timeouts
- Integration tests may take longer due to HTTP mocking
- Increase timeout if needed: `@tag timeout: 60_000`

## Next Steps

1. **Run the tests** to verify everything works
2. **Add more scenarios** as needed (e.g., concurrent scans, large syncs)
3. **Extend fixtures** for more complex test data
4. **Add performance tests** for large attendee lists

## Example Usage

```elixir
# In your own tests, you can use the fixtures:
import FastCheck.Fixtures

test "my custom test" do
  event = create_event(%{name: "My Event"})
  attendee = create_attendee(event, %{ticket_code: "CUSTOM-123"})
  
  # Your test logic
end
```
