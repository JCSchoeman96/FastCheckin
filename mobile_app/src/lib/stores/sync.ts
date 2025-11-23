import { browser } from '$app/environment';
import { API_ENDPOINTS, CACHE_TTL_MS } from '$lib/config';
import { db, expireCache, getConflictTasks, getPendingScans, processScanResults, resolveConflictTasks, saveSyncData } from '$lib/db';
import type { ScanQueueItem, ScanUploadResponse, SyncResponse } from '$lib/types';
import { get } from 'svelte/store';
import { auth } from './auth';
import { notifications } from './notifications';

type SyncDependencies = {
  fetch: typeof fetch;
  db: typeof db;
  expireCache: typeof expireCache;
  getConflictTasks: typeof getConflictTasks;
  getPendingScans: typeof getPendingScans;
  processScanResults: typeof processScanResults;
  resolveConflictTasks: typeof resolveConflictTasks;
  saveSyncData: typeof saveSyncData;
  notifications: typeof notifications;
  getAuthToken: () => string | null;
  getAuthEventId: () => number | null;
  handleAuthError: (message: string) => Promise<void> | void;
  cacheTtlMs: number;
};

const defaultDeps: SyncDependencies = {
  fetch,
  db,
  expireCache,
  getConflictTasks,
  getPendingScans,
  processScanResults,
  resolveConflictTasks,
  saveSyncData,
  notifications,
  getAuthToken: () => get(auth).token,
  getAuthEventId: () => get(auth).event_id,
  handleAuthError: message => auth.handleUnauthorized(message),
  cacheTtlMs: CACHE_TTL_MS
};

interface SyncOptions {
  attachNetworkHandlers?: boolean;
  initialOnline?: boolean;
}

export class SyncStore {
  isOnline = $state(false);
  isSyncing = $state(false);
  queueLength = $state(0);
  attendeeCount = $state(0);
  conflictCount = $state(0);
  cacheNeedsRefresh = $state(false);
  cacheNotice: string | null = $state(null);
  conflictNoticeId: string | null = $state(null);
  lastSync: string | null = $state(null);

  private deps: SyncDependencies;
  private attachNetworkHandlers: boolean;

  constructor(deps: Partial<SyncDependencies> = {}, options: SyncOptions = {}) {
    this.deps = { ...defaultDeps, ...deps };
    this.isOnline = options.initialOnline ?? (browser ? navigator.onLine : true);
    this.attachNetworkHandlers = options.attachNetworkHandlers ?? browser;

    if (browser && this.attachNetworkHandlers) {
      window.addEventListener('online', this.handleOnline);
      window.addEventListener('offline', this.handleOffline);
    }

    // Prime state
    this.refreshCacheState();
    this.refreshConflicts();
    this.refreshCounts();

    if (browser && this.isOnline) {
      this.syncAll();
    }
  }

  destroy() {
    if (browser && this.attachNetworkHandlers) {
      window.removeEventListener('online', this.handleOnline);
      window.removeEventListener('offline', this.handleOffline);
    }
  }

  private handleOnline = () => {
    this.isOnline = true;
    setTimeout(() => {
      if (this.isOnline) {
        this.syncAll();
      }
    }, 500);
  };

  private handleOffline = () => {
    this.isOnline = false;
  };

  private async refreshCounts(): Promise<void> {
    const [attendeeCount, queueItems, conflicts] = await Promise.all([
      this.deps.db.attendees.count(),
      this.deps.getPendingScans(),
      this.deps.getConflictTasks()
    ]);

    this.attendeeCount = attendeeCount;
    const blockedScans = conflicts.filter(task => task.type === 'scan').length;
    this.queueLength = queueItems.length + blockedScans;
    this.conflictCount = conflicts.length;
  }

  async refreshCacheState(): Promise<void> {
    const { attendeesExpired, kvExpired } = await this.deps.expireCache(this.deps.cacheTtlMs);
    const expired = attendeesExpired + kvExpired;

    this.attendeeCount = await this.deps.db.attendees.count();

    if (expired > 0) {
      this.cacheNeedsRefresh = true;
      this.cacheNotice = 'Cached data expired. Please sync attendees to continue.';
      this.deps.notifications.info('Cache expired. Refreshing data is required.');
    } else if (this.attendeeCount === 0) {
      this.cacheNeedsRefresh = true;
      this.cacheNotice = 'No attendee data found. Please sync before scanning.';
    } else {
      this.cacheNeedsRefresh = false;
      this.cacheNotice = null;
    }
  }

  async refreshConflicts(): Promise<void> {
    const conflicts = await this.deps.getConflictTasks();
    this.conflictCount = conflicts.length;

    if (conflicts.length === 0) {
      if (this.conflictNoticeId) {
        this.deps.notifications.remove(this.conflictNoticeId);
        this.conflictNoticeId = null;
      }
      return;
    }

    const message = conflicts.length === 1
      ? '1 sync conflict requires attention'
      : `${conflicts.length} sync conflicts require attention`;

    if (this.conflictNoticeId) {
      this.deps.notifications.remove(this.conflictNoticeId);
    }

    this.conflictNoticeId = this.deps.notifications.conflict(message, [
      { label: 'Retry', handler: () => this.retryConflicts(false) },
      { label: 'Override', handler: () => this.retryConflicts(true) }
    ]);
  }

  retryConflicts = async (overrideWithServer: boolean): Promise<void> => {
    await this.deps.resolveConflictTasks(overrideWithServer);
    await this.refreshConflicts();

    if (!overrideWithServer) {
      await this.syncPendingScans();
    }

    await this.syncAttendees();
  };

  async syncAll(): Promise<void> {
    if (this.isSyncing || !this.isOnline || !this.deps.getAuthToken() || !this.deps.getAuthEventId()) return;

    this.isSyncing = true;
    try {
      await this.syncUp();
      await this.syncAttendees();
      await this.refreshCacheState();
      await this.refreshConflicts();
    } catch (error) {
      console.error('Sync sequence failed:', error);
    } finally {
      this.isSyncing = false;
    }
  }

  async syncAttendees(): Promise<void> {
    if (!this.isOnline) return;
    this.isSyncing = true;

    try {
      const token = this.deps.getAuthToken();
      if (!token) {
        await this.deps.handleAuthError('No active session. Please log in again.');
        return;
      }

      if (!this.deps.getAuthEventId()) {
        await this.deps.handleAuthError('No event selected. Please log in again.');
        return;
      }

      const lastSyncItem = await this.deps.db.kv_store.get('last_sync');
      const since = lastSyncItem?.value;

      let url = API_ENDPOINTS.ATTENDEES;
      if (since) {
        url += `?since=${encodeURIComponent(since)}`;
      }

      const response = await this.deps.fetch(url, {
        headers: { 'Authorization': `Bearer ${token}` }
      });

      if (response.status === 401) {
        await this.deps.handleAuthError('Session expired. Please log in again.');
        throw new Error('Unauthorized');
      }

      const responseData: SyncResponse = await response.json();

      if (!response.ok || responseData.error) {
        const message = responseData.error?.message || response.statusText;
        this.deps.notifications.error(`Sync failed: ${message}`);
        throw new Error(`Sync down failed: ${message}`);
      }

      await this.deps.saveSyncData(responseData.data.attendees, responseData.data.server_time);

      this.cacheNeedsRefresh = false;
      this.cacheNotice = null;
      this.lastSync = responseData.data.server_time;
      await this.refreshCounts();
      await this.refreshConflicts();
    } catch (error) {
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
      const token = this.deps.getAuthToken();
      if (!token) {
        await this.deps.handleAuthError('No active session. Please log in again.');
        return;
      }

      const eventId = this.deps.getAuthEventId();
      if (!eventId) {
        await this.deps.handleAuthError('No event selected. Please log in again.');
        return;
      }

      const pendingScans = await this.deps.getPendingScans();
      const eventScans = pendingScans.filter(scan => scan.event_id === eventId);

      if (eventScans.length === 0) {
        const conflicts = await this.deps.getConflictTasks();
        const blockedScans = conflicts.filter(task => task.type === 'scan').length;
        this.queueLength = blockedScans;
        await this.refreshConflicts();
        return;
      }

      this.isSyncing = true;

      const batches = eventScans.reduce<Record<number, { event_id: number; scans: ScanQueueItem[] }>>((acc, scan) => {
        const normalized: ScanQueueItem = { ...scan, scan_version: scan.scan_version || scan.scanned_at };

        if (!acc[scan.event_id]) {
          acc[scan.event_id] = { event_id: scan.event_id, scans: [] };
        }

        acc[scan.event_id].scans.push(normalized);
        return acc;
      }, {});

      const response = await this.deps.fetch(API_ENDPOINTS.BATCH_CHECKIN, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`
        },
        body: JSON.stringify({ batches: Object.values(batches) })
      });

      if (response.status === 401) {
        await this.deps.handleAuthError('Session expired. Please log in again.');
        throw new Error('Unauthorized');
      }

      const responseData: ScanUploadResponse = await response.json();

      if (!response.ok || responseData.error) {
        const message = responseData.error?.message || response.statusText;
        this.deps.notifications.error(`Upload failed: ${message}`);
        throw new Error(`Sync up failed: ${message}`);
      }

      await this.deps.processScanResults(responseData.data.results);
      await this.refreshCounts();
      await this.refreshConflicts();
    } catch (error) {
      console.error('Sync up error:', error);
    } finally {
      this.isSyncing = false;
    }
  }

  async syncUp(): Promise<void> {
    return this.syncPendingScans();
  }
}

export const createSyncStore = (
  deps: Partial<SyncDependencies> = {},
  options: SyncOptions = {}
): SyncStore => new SyncStore(deps, options);

export const syncStore = createSyncStore();
