import { browser } from '$app/environment';

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
    // TODO: Implement login logic
    return false;
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
