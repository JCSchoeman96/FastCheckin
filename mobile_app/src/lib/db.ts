import Dexie, { type Table } from 'dexie';
import type { Attendee, ScanQueueItem } from './types';

export interface KVItem {
  key: string;
  value: any;
}

export class FastCheckDB extends Dexie {
  attendees!: Table<Attendee, number>;
  queue!: Table<ScanQueueItem, number>;
  kv_store!: Table<KVItem, string>;

  constructor() {
    super('FastCheckDB');
    
    this.version(1).stores({
      // Compound index for fast lookups by event+code (critical for scanning)
      // ticket_code and event_id indexed separately for flexibility
      attendees: '++id, [event_id+ticket_code], ticket_code, event_id',
      
      // Queue needs to be ordered by time (scanned_at) or id
      // idempotency_key must be unique to prevent double-processing
      queue: '++id, idempotency_key, [event_id+sync_status]',
      
      // Simple key-value store for config/state
      kv_store: 'key'
    });
  }
}

export const db = new FastCheckDB();

/**
 * Saves attendees from a sync response and updates the last sync time.
 * Performed in a single transaction to ensure consistency.
 */
export async function saveSyncData(attendees: Attendee[], serverTime: string): Promise<void> {
  await db.transaction('rw', db.attendees, db.kv_store, async () => {
    // Bulk upsert attendees if any
    if (attendees.length > 0) {
      await db.attendees.bulkPut(attendees);
    }
    
    // Update last sync timestamp
    await db.kv_store.put({ key: 'last_sync', value: serverTime });
  });
}
