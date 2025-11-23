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

  const syncPendingScans = async () => {
    const $auth = get(auth);
    if (!$auth.token) return;

    // Get pending scans
    const pendingScans = await import('$lib/db').then(m => m.getPendingScans());

    if (pendingScans.length === 0) return 0;

    update(s => ({ ...s, isSyncing: true, error: null }));

    try {
      const scans = pendingScans.map(scan => ({
        ...scan,
        scan_version: scan.scan_version || scan.scanned_at
      } satisfies ScanQueueItem));

      const response = await fetch(API_ENDPOINTS.BATCH_CHECKIN, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${$auth.token}`
        },
        body: JSON.stringify({ scans })
      });

      if (!response.ok) throw new Error(`Sync up failed: ${response.statusText}`);

      const responseData = await response.json();
      const { data, error } = responseData;

      if (error) throw new Error(error.message || 'Sync up failed');

      // Process results
      await import('$lib/db').then(m => m.processScanResults(data.results));

      // Update pending count
      const pendingCount = await db.queue.where('sync_status').equals('pending').count();

      update(s => ({
        ...s,
        isSyncing: false,
        pendingCount
      }));

      return data.results.length;
      } catch (err: any) {
        update(s => ({
          ...s,
          isSyncing: false,
          error: err.message || 'Sync up failed'
        }));
        throw err;
      }
    };

  if (typeof window !== 'undefined') {
    window.addEventListener('online', () => {
      syncPendingScans();
    });
  }

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

      if (typeof navigator !== 'undefined' && navigator.onLine) {
        syncPendingScans();
      }
    },

    // Sync Down: Fetch attendees from server
    syncAttendees: async () => {
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

        const responseData: SyncResponse = await response.json();
        const { data, error } = responseData;

        if (error) throw new Error(error.message || 'Sync down failed');

        // Update DB using helper
        await import('$lib/db').then(m => m.saveSyncData(data.attendees, data.server_time));

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

    // Alias for backward compatibility
    syncDown: async () => {
      return sync.syncAttendees();
    },

    // Sync Up: Upload queued scans
    syncPendingScans,

    // Alias for backward compatibility
    syncUp: async () => {
      return syncPendingScans();
    },
    
    // Refresh pending count helper
    refreshCount: async () => {
      const pendingCount = await db.queue.where('sync_status').equals('pending').count();
      update(s => ({ ...s, pendingCount }));
    }
  };
}

export const sync = createSyncStore();
