import Dexie, { type Table } from 'dexie';
import type { Attendee, ScanQueueItem } from './types';
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
  }
}

export const db = new FastCheckDB();

function withTimestamps<T extends { created_at?: string; updated_at?: string }>(
  item: T,
  now: string
): T {
  return {
    ...item,
    created_at: item.created_at || now,
    updated_at: now
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

  await db.transaction('rw', db.attendees, db.kv_store, async () => {
    const now = new Date().toISOString();

    // Bulk upsert attendees if any
    if (attendees.length > 0) {
      const stampedAttendees = attendees.map(attendee => withTimestamps(attendee, now));
      await db.attendees.bulkPut(stampedAttendees);
    }

    // Update last sync timestamp
    await db.kv_store.put(withTimestamps({ key: 'last_sync', value: serverTime }, now));
  });
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
  await db.queue.add({
    ...scan,
    idempotency_key: scan.idempotency_key || uuidv4(),
    sync_status: 'pending'
  });
}

export async function getPendingScans(): Promise<ScanQueueItem[]> {
  return await db.queue
    .where('sync_status')
    .equals('pending')
    .toArray();
}

export async function processScanResults(
  results: { idempotency_key: string; status: string; message: string }[]
): Promise<void> {
  await db.transaction('rw', db.queue, async () => {
    for (const result of results) {
      // Backend returns "SUCCESS" for success, anything else is an error (e.g. "INVALID_TICKET")
      const isSuccess = result.status.toUpperCase() === 'SUCCESS';
      
      // Find scan by idempotency_key
      const scan = await db.queue
        .where('idempotency_key')
        .equals(result.idempotency_key)
        .first();

      if (scan && scan.id) {
        if (isSuccess) {
          // Success or duplicate - remove from queue
          await db.queue.delete(scan.id);
        } else {
          // Error - mark as failed so it can be retried or inspected
          await db.queue.update(scan.id, {
            sync_status: 'error',
            error_message: result.message || result.status
          });
        }
      }
    }
  });
}
