import { browser } from '$app/environment';
import { API_ENDPOINTS } from '$lib/config';
import { setJWT, setCurrentEventId } from '$lib/db';

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
    }
  }

  handleOnline = () => {
    this.isOnline = true;
    this.syncUp(); // Auto-trigger sync when back online
  };

  handleOffline = () => {
    this.isOnline = false;
  };

  async login(eventId: string, deviceName: string): Promise<boolean> {
    if (!this.isOnline) return false;

    try {
      const response = await fetch(API_ENDPOINTS.LOGIN, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ event_id: parseInt(eventId), device_name: deviceName })
      });

      if (!response.ok) {
        console.error('Login failed:', response.statusText);
        return false;
      }

      const data = await response.json();
      
      // Persist auth state
      await setJWT(data.token);
      await setCurrentEventId(data.event_id);
      
      return true;
    } catch (error) {
      console.error('Login error:', error);
      return false;
    }
  }

  async syncDown(): Promise<void> {
    // TODO: Implement sync down logic
    if (!this.isOnline) return;
    this.isSyncing = true;
    try {
      // ...
    } finally {
      this.isSyncing = false;
    }
  }

  async syncUp(): Promise<void> {
    // TODO: Implement sync up logic
    if (!this.isOnline) return;
    this.isSyncing = true;
    try {
      // ...
    } finally {
      this.isSyncing = false;
    }
  }

  destroy() {
    if (browser) {
      window.removeEventListener('online', this.handleOnline);
      window.removeEventListener('offline', this.handleOffline);
    }
  }
}

export const syncStore = new SyncStore();
