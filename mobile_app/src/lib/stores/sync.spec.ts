import { describe, expect, it, vi } from 'vitest';
import { createSyncStore } from './sync';
import type { ScanQueueItem } from '$lib/types';

type MockDeps = Parameters<typeof createSyncStore>[0];

const createMockDeps = (): MockDeps => {
  const queue: ScanQueueItem[] = [];

  return {
    fetch: vi.fn(),
    db: {
      attendees: {
        count: vi.fn().mockResolvedValue(0)
      },
      kv_store: {
        get: vi.fn().mockResolvedValue(null)
      }
    } as any,
    expireCache: vi.fn().mockResolvedValue({ attendeesExpired: 0, kvExpired: 0 }),
    getConflictTasks: vi.fn().mockResolvedValue([]),
    getJWT: vi.fn().mockResolvedValue('token'),
    getPendingScans: vi.fn().mockImplementation(async () => queue),
    processScanResults: vi.fn(),
    resolveConflictTasks: vi.fn(),
    saveSyncData: vi.fn(),
    setCurrentEventId: vi.fn(),
    setJWT: vi.fn(),
    notifications: {
      info: vi.fn(),
      error: vi.fn(),
      success: vi.fn(),
      conflict: vi.fn().mockReturnValue('conflict-id'),
      remove: vi.fn()
    } as any,
    cacheTtlMs: 1_000
  };
};

describe('sync store', () => {
  it('uploads pending scans and updates queue length', async () => {
    const deps = createMockDeps();
    const pending: ScanQueueItem[] = [
      {
        id: 1,
        event_id: 1,
        idempotency_key: 'key-1',
        ticket_code: 'A',
        direction: 'in',
        scanned_at: '2024-01-01T00:00:00Z',
        sync_status: 'pending'
      },
      {
        id: 2,
        event_id: 2,
        idempotency_key: 'key-2',
        ticket_code: 'B',
        direction: 'out',
        scanned_at: '2024-01-01T00:00:01Z',
        sync_status: 'pending'
      }
    ];

    // First call (constructor) -> [], second -> pending, remainder -> []
    deps.getPendingScans = vi
      .fn()
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce(pending)
      .mockResolvedValue([]);

    deps.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        data: {
          results: pending.map(item => ({
            idempotency_key: item.id?.toString() ?? item.ticket_code,
            status: 'success',
            server_state: { attendee: { ...item, event_id: item.event_id, ticket_code: item.ticket_code } }
          }))
        },
        error: null
      })
    } as any);

    const store = createSyncStore(deps, { attachNetworkHandlers: false, initialOnline: true });
    await store.syncPendingScans();

    expect(deps.fetch).toHaveBeenCalledWith(
      expect.stringContaining('/batch-checkin'),
      expect.objectContaining({ method: 'POST' })
    );
    expect(deps.processScanResults).toHaveBeenCalled();
    expect(store.queueLength).toBe(0);
  });

  it('downloads attendees and refreshes cache state', async () => {
    const deps = createMockDeps();
    deps.db.attendees.count = vi
      .fn()
      .mockResolvedValueOnce(0)
      .mockResolvedValueOnce(1)
      .mockResolvedValue(1);

    deps.fetch = vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: async () => ({
        data: {
          attendees: [
            {
              id: 1,
              event_id: 1,
              first_name: 'Test',
              last_name: 'User',
              email: 'test@example.com',
              ticket_type: 'General',
              allowed_checkins: 1,
              checkins_remaining: 1,
              payment_status: 'paid',
              is_currently_inside: false,
              checked_in_at: null,
              checked_out_at: null,
              updated_at: '2024-01-01T00:00:00Z',
              created_at: '2024-01-01T00:00:00Z',
              ticket_code: 'A'
            }
          ],
          server_time: '2024-01-02T00:00:00Z'
        },
        error: null
      })
    } as any);

    const store = createSyncStore(deps, { attachNetworkHandlers: false, initialOnline: true });
    await store.syncAttendees();

    expect(deps.saveSyncData).toHaveBeenCalled();
    expect(store.cacheNeedsRefresh).toBe(false);
    expect(store.attendeeCount).toBe(1);
    expect(store.lastSync).toBe('2024-01-02T00:00:00Z');
  });

  it('retries conflicts and triggers follow-up syncs', async () => {
    const deps = createMockDeps();
    deps.getConflictTasks = vi.fn().mockResolvedValue([{ type: 'scan', id: 1 } as any]);

    const store = createSyncStore(deps, { attachNetworkHandlers: false, initialOnline: true });
    const syncUpSpy = vi.spyOn(store, 'syncPendingScans').mockResolvedValue();
    const syncDownSpy = vi.spyOn(store, 'syncAttendees').mockResolvedValue();

    await store.retryConflicts(false);

    expect(deps.resolveConflictTasks).toHaveBeenCalledWith(false);
    expect(syncUpSpy).toHaveBeenCalled();
    expect(syncDownSpy).toHaveBeenCalled();
  });
});
