import Dexie, { type Table } from 'dexie';
import type { Attendee, ConflictTask, ScanQueueItem } from './types';
import { CACHE_TTL_MS } from './config';

export interface KVItem {
  key: string;
  value: any;
  created_at?: string;
  updated_at?: string;
}

export class FastCheckDB extends Dexie {
  attendees!: Table<Attendee, number>;
  queue!: Table<ScanQueueItem, number>;
  kv_store!: Table<KVItem, string>;

  constructor() {
    super('FastCheckDB');

    this.version(1).stores({
      attendees: '++id, [event_id+ticket_code], ticket_code, event_id',
      queue: '++id, idempotency_key, [event_id+sync_status]',
      kv_store: 'key'
    });

    this.version(2)
      .stores({
        // Compound index for fast lookups by event+code (critical for scanning)
        // ticket_code and event_id indexed separately for flexibility
        attendees: '++id, [event_id+ticket_code], ticket_code, event_id, updated_at',

        // Queue needs to be ordered by time (scanned_at) or id
        // idempotency_key must be unique to prevent double-processing
        queue: '++id, idempotency_key, [event_id+sync_status]',

        // Simple key-value store for config/state
        kv_store: 'key, updated_at'
      })
      .upgrade(async tx => {
        const now = new Date().toISOString();

        await tx.table('attendees').toCollection().modify((record: any) => {
          record.created_at = record.created_at || now;
          record.updated_at = record.updated_at || now;
        });

        await tx.table('kv_store').toCollection().modify((record: any) => {
          record.created_at = record.created_at || now;
          record.updated_at = record.updated_at || now;
        });
      });

    this.version(3)
      .stores({
        attendees: '++id, [event_id+ticket_code], ticket_code, event_id, updated_at',
        queue: '++id, idempotency_key, [event_id+sync_status]',
        kv_store: 'key, updated_at'
      })
      .upgrade(async tx => {
        const now = new Date().toISOString();

        await tx.table('queue').toCollection().modify((record: any) => {
          record.scan_version = record.scan_version || record.scanned_at || now;
          record.sync_status = record.sync_status || 'pending';
        });

        await tx.table('attendees').toCollection().modify((record: any) => {
          record.conflict = record.conflict || false;
        });
      });
  }
}

export const db = new FastCheckDB();

function withTimestamps<T extends Record<string, any>>(item: T, now: string): T & { created_at: string; updated_at: string } {
  return {
    ...item,
    created_at: (item as any).created_at || now,
    updated_at: (item as any).updated_at || now
  };
}

export async function expireCache(ttlMs: number): Promise<{ attendeesExpired: number; kvExpired: number }> {
  const cutoffIso = new Date(Date.now() - ttlMs).toISOString();

  const [attendeesExpired, kvExpired] = await db.transaction('rw', db.attendees, db.kv_store, async () => {
    const attendeesExpired = await db.attendees.where('updated_at').below(cutoffIso).delete();
    const kvExpired = await db.kv_store.where('updated_at').below(cutoffIso).delete();

    return [attendeesExpired, kvExpired];
  });

  return { attendeesExpired, kvExpired };
}

/**
 * Saves attendees from a sync response and updates the last sync time.
 * Performed in a single transaction to ensure consistency.
 */
export async function saveSyncData(attendees: Attendee[], serverTime: string): Promise<void> {
  await expireCache(CACHE_TTL_MS);

  const conflictTasks: ConflictTask[] = [];

  await db.transaction('rw', db.attendees, db.kv_store, async () => {
    const now = new Date().toISOString();

    if (attendees.length > 0) {
      const stampedAttendees: Attendee[] = [];

      for (const attendee of attendees) {
        const existing = await db.attendees
          .where('[event_id+ticket_code]')
          .equals([attendee.event_id, attendee.ticket_code])
          .first();

        const incoming = withTimestamps({ ...attendee, conflict: false, server_state: undefined, local_state: undefined }, now);

        if (existing) {
          const incomingUpdated = attendee.updated_at ? Date.parse(attendee.updated_at) : 0;
          const localUpdated = existing.updated_at ? Date.parse(existing.updated_at) : 0;
          const hasMismatch =
            existing.is_currently_inside !== attendee.is_currently_inside ||
            existing.checkins_remaining !== attendee.checkins_remaining ||
            existing.checked_in_at !== attendee.checked_in_at ||
            existing.checked_out_at !== attendee.checked_out_at;

          if (hasMismatch && incomingUpdated !== localUpdated) {
            conflictTasks.push({
              type: 'attendee',
              attendee_id: existing.id,
              ticket_code: attendee.ticket_code,
              event_id: attendee.event_id,
              local_state: existing,
              server_state: attendee,
              detected_at: now
            });

            stampedAttendees.push(
              withTimestamps({ ...existing, conflict: true, server_state: attendee, local_state: existing }, now)
            );
            continue;
          }
        }

        stampedAttendees.push(incoming);
      }

      if (stampedAttendees.length > 0) {
        await db.attendees.bulkPut(stampedAttendees);
      }
    }

    await db.kv_store.put(withTimestamps({ key: 'last_sync', value: serverTime }, now));
  });

  if (conflictTasks.length > 0) {
    await appendConflictTasks(conflictTasks);
  }
}

/**
 * Auth Persistence Helpers
 * Abstracts storage of auth state (JWT, Event ID) to allow easy swapping
 * of storage engines (Dexie vs Capacitor Preferences) later.
 */
import { Capacitor } from '@capacitor/core';
import { Preferences } from '@capacitor/preferences';

export async function setJWT(token: string | null): Promise<void> {
  if (Capacitor.isNativePlatform()) {
    if (token) {
      await Preferences.set({ key: 'jwt', value: token });
    } else {
      await Preferences.remove({ key: 'jwt' });
    }
  } else {
    const now = new Date().toISOString();
    if (token) {
      await db.kv_store.put(withTimestamps({ key: 'jwt', value: token }, now));
    } else {
      await db.kv_store.delete('jwt');
    }
  }
}

export async function getJWT(): Promise<string | null> {
  if (Capacitor.isNativePlatform()) {
    const { value } = await Preferences.get({ key: 'jwt' });
    return value;
  } else {
    const item = await db.kv_store.get('jwt');
    return item?.value || null;
  }
}

export async function setCurrentEventId(eventId: number | null): Promise<void> {
  const value = eventId ? eventId.toString() : null;
  
  if (Capacitor.isNativePlatform()) {
    if (value) {
      await Preferences.set({ key: 'current_event_id', value });
    } else {
      await Preferences.remove({ key: 'current_event_id' });
    }
  } else {
    const now = new Date().toISOString();
    if (eventId) {
      await db.kv_store.put(withTimestamps({ key: 'current_event_id', value: eventId }, now));
    } else {
      await db.kv_store.delete('current_event_id');
    }
  }
}

export async function getCurrentEventId(): Promise<number | null> {
  if (Capacitor.isNativePlatform()) {
    const { value } = await Preferences.get({ key: 'current_event_id' });
    return value ? parseInt(value, 10) : null;
  } else {
    const item = await db.kv_store.get('current_event_id');
    return item?.value || null;
  }
}

/**
 * Queue Helpers
 * Encapsulates logic for adding scans, fetching pending items, and processing results.
 */
import { v4 as uuidv4 } from 'uuid';

export async function addScanToQueue(
  scan: Omit<ScanQueueItem, 'id' | 'sync_status' | 'idempotency_key'> & { idempotency_key?: string }
): Promise<void> {
  const scan_version = scan.scan_version || scan.scanned_at || new Date().toISOString();

  await db.queue.add({
    ...scan,
    idempotency_key: scan.idempotency_key || uuidv4(),
    scan_version,
    sync_status: 'pending'
  });
}

export async function getPendingScans(): Promise<ScanQueueItem[]> {
  return await db.queue
    .where('sync_status')
    .equals('pending')
    .toArray();
}

export async function getConflictTasks(): Promise<ConflictTask[]> {
  const record = await db.kv_store.get('conflict_tasks');
  return record?.value || [];
}

export async function appendConflictTasks(tasks: ConflictTask[]): Promise<void> {
  if (tasks.length === 0) return;

  const now = new Date().toISOString();
  const existing = await getConflictTasks();
  await db.kv_store.put(withTimestamps({ key: 'conflict_tasks', value: [...existing, ...tasks] }, now));
}

export async function clearConflictTasks(): Promise<void> {
  const now = new Date().toISOString();
  await db.kv_store.put(withTimestamps({ key: 'conflict_tasks', value: [] }, now));
}

export async function resolveConflictTasks(overrideWithServer: boolean): Promise<void> {
  const tasks = await getConflictTasks();
  if (tasks.length === 0) return;

  const now = new Date().toISOString();

  await db.transaction('rw', db.queue, db.attendees, async () => {
    for (const task of tasks) {
      if (task.type === 'scan' && task.queue_id) {
        const updates: Partial<ScanQueueItem> = {
          sync_status: 'pending',
          error_message: undefined,
          scan_version: now,
          server_state: overrideWithServer ? undefined : task.server_state,
          local_state: overrideWithServer ? undefined : task.local_state
        };

        if (overrideWithServer && task.server_state) {
          updates.server_state = undefined;
          updates.local_state = undefined;
        }

        await db.queue.update(task.queue_id, updates);
      }

      if (task.type === 'attendee') {
        const baseState = overrideWithServer ? task.server_state || task.local_state : task.local_state || task.server_state;

        if (baseState) {
          const normalized = withTimestamps(
            { ...(baseState as Attendee), conflict: false, server_state: undefined, local_state: undefined },
            now
          ) as Attendee;

          await db.attendees.put(normalized);
        }
      }
    }
  });

  await clearConflictTasks();
}

export async function processScanResults(
  results: { idempotency_key: string; status: string; message: string; server_state?: any }[]
): Promise<void> {
  const conflictTasks: ConflictTask[] = [];
  const now = new Date().toISOString();

  await db.transaction('rw', db.queue, async () => {
    for (const result of results) {
      const status = result.status.toLowerCase();
      const isSuccess = status === 'success' || status === 'duplicate';
      const isConflict = status === 'conflict';

      const scan = await db.queue
        .where('idempotency_key')
        .equals(result.idempotency_key)
        .first();

      if (scan && scan.id) {
        if (isSuccess) {
          await db.queue.delete(scan.id);
        } else if (isConflict) {
          await db.queue.update(scan.id, {
            sync_status: 'conflict',
            error_message: result.message || result.status,
            server_state: result.server_state,
            local_state: scan
          });

          conflictTasks.push({
            type: 'scan',
            queue_id: scan.id,
            event_id: scan.event_id,
            ticket_code: scan.ticket_code,
            idempotency_key: scan.idempotency_key,
            server_state: result.server_state,
            local_state: scan,
            detected_at: now
          });
        } else {
          await db.queue.update(scan.id, {
            sync_status: 'error',
            error_message: result.message || result.status
          });
        }
      }
    }
  });

  if (conflictTasks.length > 0) {
    await appendConflictTasks(conflictTasks);
  }
}
