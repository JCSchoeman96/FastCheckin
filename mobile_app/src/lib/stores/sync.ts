import { writable, get } from 'svelte/store';
import { db } from '$lib/db';
import { auth } from './auth';
import { API_ENDPOINTS } from '$lib/config';
import type { SyncResponse, ScanUploadResponse, ScanQueueItem } from '$lib/types';

export interface SyncState {
  isSyncing: boolean;
  lastSync: string | null;
  error: string | null;
  pendingCount: number;
}

function createSyncStore() {
  const { subscribe, set, update } = writable<SyncState>({
    isSyncing: false,
    lastSync: null,
    error: null,
    pendingCount: 0
  });

  return {
    subscribe,

    // Initialize sync state from DB
    init: async () => {
      const lastSyncItem = await db.kv_store.get('last_sync');
      const pendingCount = await db.queue.where('sync_status').equals('pending').count();
      
      update(s => ({
        ...s,
        lastSync: lastSyncItem?.value || null,
        pendingCount
      }));
    },

    // Sync Down: Fetch attendees from server
    syncDown: async () => {
      const $auth = get(auth);
      if (!$auth.token || !$auth.event_id) return;

      update(s => ({ ...s, isSyncing: true, error: null }));

      try {
        // Get last sync time
        const lastSyncItem = await db.kv_store.get('last_sync');
        const since = lastSyncItem?.value;
        
        // Build URL
        let url = API_ENDPOINTS.ATTENDEES;
        if (since) {
          url += `?since=${encodeURIComponent(since)}`;
        }

        const response = await fetch(url, {
          headers: {
            'Authorization': `Bearer ${$auth.token}`
          }
        });

        if (!response.ok) throw new Error('Sync down failed');

        const data: SyncResponse = await response.json();

        // Update DB in transaction
        await db.transaction('rw', db.attendees, db.kv_store, async () => {
          // Bulk put attendees (upsert)
          if (data.attendees.length > 0) {
            await db.attendees.bulkPut(data.attendees);
          }
          
          // Update last sync time
          await db.kv_store.put({ key: 'last_sync', value: data.server_time });
        });

        update(s => ({
          ...s,
          isSyncing: false,
          lastSync: data.server_time
        }));

        return data.count;
      } catch (err: any) {
        update(s => ({
          ...s,
          isSyncing: false,
          error: err.message || 'Sync down failed'
        }));
        throw err;
      }
    },

    // Sync Up: Upload queued scans
    syncUp: async () => {
      const $auth = get(auth);
      if (!$auth.token) return;

      // Get pending scans
      const pendingScans = await db.queue
        .where('sync_status')
        .equals('pending')
        .toArray();

      if (pendingScans.length === 0) return 0;

      update(s => ({ ...s, isSyncing: true, error: null }));

      try {
        const response = await fetch(API_ENDPOINTS.SCANS, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            'Authorization': `Bearer ${$auth.token}`
          },
          body: JSON.stringify({ scans: pendingScans })
        });

        if (!response.ok) throw new Error('Sync up failed');

        const data: ScanUploadResponse = await response.json();

        // Process results
        await db.transaction('rw', db.queue, async () => {
          for (const result of data.results) {
            const status = result.status === 'error' ? 'error' : 'synced';
            
            // Find scan by idempotency_key
            const scan = await db.queue
              .where('idempotency_key')
              .equals(result.idempotency_key)
              .first();

            if (scan && scan.id) {
              await db.queue.update(scan.id, {
                sync_status: status,
                error_message: result.message
              });
            }
          }
        });

        // Update pending count
        const pendingCount = await db.queue.where('sync_status').equals('pending').count();

        update(s => ({
          ...s,
          isSyncing: false,
          pendingCount
        }));

        return data.processed;
      } catch (err: any) {
        update(s => ({
          ...s,
          isSyncing: false,
          error: err.message || 'Sync up failed'
        }));
        throw err;
      }
    },
    
    // Refresh pending count helper
    refreshCount: async () => {
      const pendingCount = await db.queue.where('sync_status').equals('pending').count();
      update(s => ({ ...s, pendingCount }));
    }
  };
}

export const sync = createSyncStore();
