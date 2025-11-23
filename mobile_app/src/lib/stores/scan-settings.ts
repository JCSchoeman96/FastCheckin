import { browser } from '$app/environment';
import { db } from '$lib/db';
import { writable } from 'svelte/store';

export interface ScanMetadata {
  entranceName: string;
  operatorName: string;
}

export const DEFAULT_SCAN_METADATA: ScanMetadata = {
  entranceName: 'Mobile',
  operatorName: 'Mobile Scanner'
};

const STORAGE_KEY = 'scan_metadata';

function createScanSettingsStore() {
  const { subscribe, set, update } = writable<ScanMetadata>(DEFAULT_SCAN_METADATA);

  const persist = async (value: ScanMetadata) => {
    if (!browser) return;
    const now = new Date().toISOString();
    await db.kv_store.put({ key: STORAGE_KEY, value, created_at: now, updated_at: now });
  };

  const load = async () => {
    if (!browser) return;
    const record = await db.kv_store.get(STORAGE_KEY);
    if (record?.value) {
      set({ ...DEFAULT_SCAN_METADATA, ...record.value });
    }
  };

  if (browser) {
    load().catch(console.error);
  }

  return {
    subscribe,
    set: async (value: ScanMetadata) => {
      set(value);
      await persist(value);
    },
    update: async (updater: (value: ScanMetadata) => ScanMetadata) => {
      let next: ScanMetadata | null = null;
      update(current => {
        next = updater(current);
        return next;
      });

      if (next) {
        await persist(next);
      }
    },
    reset: async () => {
      set(DEFAULT_SCAN_METADATA);
      await persist(DEFAULT_SCAN_METADATA);
    },
    load
  };
}

export const scanSettings = createScanSettingsStore();
