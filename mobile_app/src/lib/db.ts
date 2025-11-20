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
