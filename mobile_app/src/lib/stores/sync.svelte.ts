import { browser } from '$app/environment';
import { API_ENDPOINTS } from '$lib/config';
import { setJWT, setCurrentEventId, getJWT, saveSyncData, db, getPendingScans, processScanResults } from '$lib/db';
import type { SyncResponse, ScanUploadResponse } from '$lib/types';
import { notifications } from './notifications';

class SyncStore {
  // State using Svelte 5 Runes
  isOnline = $state(false);
  isSyncing = $state(false);
  queueLength = $state(0);

  constructor() {
    if (browser) {
      this.isOnline = navigator.onLine;
      window.addEventListener('online', this.handleOnline);
      window.addEventListener('offline', this.handleOffline);

      // Initial sync check
      if (this.isOnline) {
        this.syncAll();
      }
    }
  }

  handleOnline = () => {
    this.isOnline = true;
    // Debounce slightly to avoid rapid toggling
    setTimeout(() => {
      if (this.isOnline) {
        this.syncAll();
      }
    }, 1000);
  };

  handleOffline = () => {
    this.isOnline = false;
  };

  /**
   * Orchestrates a full sync: uploads pending scans, then downloads updates.
   */
  async syncAll(): Promise<void> {
    if (this.isSyncing || !this.isOnline) return;
    
    try {
      // We don't set isSyncing here because syncUp/syncDown manage it individually.
      // However, we might want to prevent overlap if called multiple times.
      // Since JS is single-threaded, the check above protects us if we await.
      
      await this.syncUp();
      await this.syncPendingScans();
      await this.syncAttendees();
    } catch (error) {
      console.error('Sync sequence failed:', error);
    }
  }


  async login(eventId: string, deviceName: string, credential: string): Promise<boolean> {
    if (!this.isOnline) return false;

    try {
      const response = await fetch(API_ENDPOINTS.LOGIN, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ event_id: parseInt(eventId), device_name: deviceName, credential })
      });

      const responseData = await response.json();

      if (!response.ok) {
        const message = responseData?.error?.message || response.statusText;
        notifications.error(`Login failed: ${message}`);
        return false;
      }

      const { data, error } = responseData;

      if (error) {
        notifications.error(`Login failed: ${error.message}`);
        return false;
      }

      if (!data?.token) {
        notifications.error('Login failed: missing token');
        return false;
      }
      
      // Persist auth state
      await setJWT(data.token);
      await setCurrentEventId(data.event_id);
      
      notifications.success('Logged in successfully');
      return true;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Unknown error';
      notifications.error(`Login error: ${message}`);
      return false;
    }
  }

  async syncAttendees(): Promise<void> {
    if (!this.isOnline) return;
    this.isSyncing = true;

    try {
      const token = await getJWT();
      if (!token) {
        throw new Error('No token found');
      }

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
          'Authorization': `Bearer ${token}`
        }
      });

      if (response.status === 401) {
        // Auth failed - clear state
        await setJWT(null);
        await setCurrentEventId(null);
        notifications.error('Session expired. Please log in again.');
        throw new Error('Unauthorized');
      }

      if (!response.ok) {
        notifications.error(`Sync failed: ${response.statusText}`);
        throw new Error(`Sync down failed: ${response.statusText}`);
      }

      const responseData: SyncResponse = await response.json();
      const { data, error } = responseData;

      if (error) {
        notifications.error(`Sync failed: ${error.message}`);
        throw new Error(error.message || 'Sync down failed');
      }

      // Save data using helper
      await saveSyncData(data.attendees, data.server_time);

    } catch (error) {
      // Error notifications already shown above, no need to duplicate
      console.error('Sync down error:', error);
    } finally {
      this.isSyncing = false;
    }
  }

  async syncDown(): Promise<void> {
    return this.syncAttendees();
  }

  async syncPendingScans(): Promise<void> {
    if (!this.isOnline) return;
    
    try {
      // 1. Get pending scans
      const pendingScans = await getPendingScans();
      if (pendingScans.length === 0) return;

      this.isSyncing = true;

      const token = await getJWT();
      if (!token) {
        throw new Error('No token found');
      }

      const currentEventId = await import('$lib/db').then(m => m.getCurrentEventId());

      // 2. Upload scans
      const response = await fetch(API_ENDPOINTS.BATCH_CHECKIN, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify({ 
          event_id: currentEventId,
          scans: pendingScans 
        })
      });

      if (response.status === 401) {
        await setJWT(null);
        await setCurrentEventId(null);
        notifications.error('Session expired. Please log in again.');
        throw new Error('Unauthorized');
      }

      if (!response.ok) {
        notifications.error(`Upload failed: ${response.statusText}`);
        throw new Error(`Sync up failed: ${response.statusText}`);
      }

      const responseData = await response.json();
      const { data, error } = responseData;

      if (error) {
        notifications.error(`Upload failed: ${error.message}`);
        throw new Error(error.message || 'Sync up failed');
      }

      // 3. Process results (cleanup queue)
      await processScanResults(data.results);

      // 4. Refresh queue length
      const remaining = await getPendingScans();
      this.queueLength = remaining.length;

    } catch (error) {
      // Error notifications already shown above, no need to duplicate
      console.error('Sync up error:', error);
    } finally {
      this.isSyncing = false;
    }
  }

  async syncUp(): Promise<void> {
    return this.syncPendingScans();
  }

  destroy() {
    if (browser) {
      window.removeEventListener('online', this.handleOnline);
      window.removeEventListener('offline', this.handleOffline);
    }
  }
}

export const syncStore = new SyncStore();
