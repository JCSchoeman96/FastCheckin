<script lang="ts">
  import { createScanService, type ScanResult, type ScanServiceOutcome } from "$lib/logic/scanner";
  import { createDeviceScanner } from "$lib/logic/device-scanner";
  import { auth } from "$lib/stores/auth";
  import { syncStore } from "$lib/stores/sync.svelte";
  import { scanSettings, DEFAULT_SCAN_METADATA, type ScanMetadata } from "$lib/stores/scan-settings";
  import type { ScanDirection, Attendee } from "$lib/types";
  import { onMount, onDestroy } from "svelte";
  import { goto } from "$app/navigation";
  import { db } from "$lib/db";
  import { Capacitor } from "@capacitor/core";
  import { notifications } from "$lib/stores/notifications";
  import { sync } from "$lib/stores/sync";

  const scanService = createScanService({
    notifier: notifications,
    triggerSync: async () => {
      await sync.syncUp();
    }
  });
  const deviceScanner = createDeviceScanner();

  // State
  let direction = $state<ScanDirection>("in");
  let ticketCode = $state("");
  let lastResult = $state<ScanResult | null>(null);
  let isProcessing = $state(false);
  let lookupResult = $state<Attendee | null>(null);
  let isNative = Capacitor.isNativePlatform();
  let isScannerActive = $state(false);
  let scanMetadata = $state<ScanMetadata>(DEFAULT_SCAN_METADATA);
  let unsubscribeScanner: (() => void) | null = null;
  let unsubscribeSettings: (() => void) | null = null;

  // Derived
  let statusColor = $derived(
    !lastResult
      ? "bg-gray-100 text-gray-500 border-gray-300"
      : lastResult.success
        ? "bg-green-500 text-white border-green-600 shadow-lg scale-105"
        : "bg-red-500 text-white border-red-600 shadow-lg scale-105"
  );
  let cacheBlocked = $derived(syncStore.attendeeCount === 0);
  let cacheWarning = $derived(syncStore.cacheNotice);
  let isNativeActive = $derived(isNative && isScannerActive);

  const refreshCache = async () => {
    await syncStore.syncAll();
  };

  onMount(() => {
    if (!$auth.token) {
      goto("/");
      return;
    }

    syncStore.refreshCacheState();

    unsubscribeScanner = deviceScanner.subscribe(code => handleScan(code));
    unsubscribeSettings = scanSettings.subscribe(value => (scanMetadata = value));

    if (!isNative) {
      startScanner();
    } else {
      scanSettings.load();
    }
  });

  onDestroy(() => {
    unsubscribeScanner?.();
    unsubscribeSettings?.();
    deviceScanner.stop();
  });

  async function startScanner() {
    await deviceScanner.start();
    isScannerActive = deviceScanner.isActive();
  }

  async function stopScanner() {
    await deviceScanner.stop();
    isScannerActive = deviceScanner.isActive();
  }

  async function handleLookup() {
    if (!ticketCode.trim() || syncStore.attendeeCount === 0) {
      lastResult = {
        success: false,
        message: "Cache empty. Please sync before scanning.",
        error_code: "CACHE_EMPTY",
      };
      return;
    }

    try {
      const eventId = $auth.event_id;
      if (!eventId) return;

      const attendee = await db.attendees.where({ event_id: eventId, ticket_code: ticketCode.trim() }).first();

      if (attendee) {
        lookupResult = attendee;
        lastResult = null; // Clear previous scan result
      } else {
        lookupResult = null;
        lastResult = {
          success: false,
          message: "Ticket not found",
          error_code: "NOT_FOUND",
        };
        await deviceScanner.handleResult?.(false);
      }
    } catch (error) {
      console.error(error);
    }
  }

  async function handleScan(code: string = ticketCode) {
    const trimmed = code.trim();
    if (!trimmed || isProcessing) return;

    if (syncStore.attendeeCount === 0) {
      lastResult = {
        success: false,
        message: "Cache empty. Please sync attendees before scanning.",
        error_code: "CACHE_EMPTY",
      };
      await deviceScanner.handleResult?.(false);
      return;
    }

    // Clear lookup on scan
    lookupResult = null;

    isProcessing = true;
    lastResult = null;

    try {
      const eventId = $auth.event_id;
      if (!eventId) {
        const noEvent: ScanServiceOutcome = {
          success: false,
          message: "No event selected. Please login.",
          error_code: "NO_EVENT",
          notifications: [{ type: "error", message: "No event selected. Please login." }],
          syncRequested: false,
        };
        lastResult = noEvent;
        await scanService.applyEffects(noEvent);
        await deviceScanner.handleResult?.(false);
        return;
      }

      const outcome = await scanService.processScan(trimmed, direction, eventId, {
        metadata: scanMetadata,
      });
      lastResult = outcome;

      await scanService.applyEffects(outcome);
      await deviceScanner.handleResult?.(outcome.success);

      if (outcome.success) {
        ticketCode = ""; // Clear input on success
      }
    } catch (e) {
      console.error(e);
      const unknown: ScanServiceOutcome = {
        success: false,
        message: "Unexpected error processing scan",
        error_code: "UNKNOWN_ERROR",
        notifications: [{ type: "error", message: "Unexpected error processing scan" }],
        syncRequested: false,
      };
      lastResult = unknown;
      await scanService.applyEffects(unknown);
      await deviceScanner.handleResult?.(false);
    } finally {
      // Add a small delay before allowing next scan to prevent double-scans
      setTimeout(() => {
        isProcessing = false;
      }, 1000);
    }
  }

  function toggleDirection() {
    direction = direction === "in" ? "out" : "in";
    lastResult = null; // Clear result on direction change
  }
</script>

<div class="scan-page-container flex flex-col h-full max-w-md mx-auto p-4 space-y-6 transition-colors duration-300">
  <!-- Header / Direction Toggle -->
  <div class="flex rounded-lg bg-gray-200 p-1 hide-on-scan transition-opacity">
    <button
      class="flex-1 py-3 text-sm font-medium rounded-md transition-all {direction === 'in'
        ? 'bg-white shadow text-blue-600'
        : 'text-gray-500 hover:text-gray-700'}"
      onclick={() => (direction = "in")}>
      Check In
    </button>
    <button
      class="flex-1 py-3 text-sm font-medium rounded-md transition-all {direction === 'out'
        ? 'bg-white shadow text-blue-600'
        : 'text-gray-500 hover:text-gray-700'}"
      onclick={() => (direction = "out")}>
      Check Out
    </button>
  </div>

  {#if syncStore.cacheNeedsRefresh}
    <div class="rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
      <div class="flex items-center justify-between gap-2">
        <p>{cacheWarning || "Cache refresh required. Please sync attendees."}</p>
        <button
          class="rounded-md bg-amber-100 px-3 py-1 text-xs font-semibold text-amber-800 disabled:opacity-50"
          onclick={refreshCache}
          disabled={syncStore.isSyncing || !syncStore.isOnline}>
          {syncStore.isSyncing ? "Syncing..." : "Refresh"}
        </button>
      </div>
    </div>
  {/if}

  <!-- Status Panel -->
  <div
    class="flex flex-col items-center justify-center p-8 rounded-xl border-2 border-dashed min-h-[200px] transition-all {statusColor} {isNativeActive
      ? 'bg-transparent border-white/50 text-white'
      : ''}">
    {#if lastResult}
      <div class="text-4xl mb-2">
        {lastResult.success ? "✅" : "❌"}
      </div>
      <h2 class="text-2xl font-bold text-center mb-1">
        {lastResult.message}
      </h2>
      {#if lastResult.attendee}
        <div class="text-sm opacity-75 text-center mt-2">
          {lastResult.attendee.first_name}
          {lastResult.attendee.last_name}
          <br />
          <span class="font-mono text-xs">{lastResult.attendee.ticket_code}</span>
        </div>
      {/if}
      {#if lastResult.error_code}
        <div class="mt-2 text-xs font-mono bg-black/10 px-2 py-1 rounded">
          {lastResult.error_code}
        </div>
      {/if}
    {:else if cacheBlocked}
      <div class="text-center space-y-2">
        <p class="text-lg font-semibold">Sync required</p>
        <p class="text-sm opacity-80">{cacheWarning || "Attendee cache is empty. Please refresh to continue."}</p>
        <button
          class="rounded-md bg-blue-600 px-4 py-2 text-white font-semibold disabled:opacity-50"
          onclick={refreshCache}
          disabled={syncStore.isSyncing || !syncStore.isOnline}>
          {syncStore.isSyncing ? "Syncing..." : "Sync attendees"}
        </button>
      </div>
    {:else if isNativeActive}
      <div class="text-white text-center">
        <p class="text-lg font-bold mb-4">Scanning...</p>
        <button class="bg-red-600 text-white px-6 py-2 rounded-full shadow-lg" onclick={stopScanner}>
          Stop Scanner
        </button>
      </div>
    {:else}
      <div class="text-4xl mb-2 text-gray-300">📷</div>
      <p class="text-center font-medium">Ready to Scan</p>
      <p class="text-xs text-center mt-1">
        Queue: {syncStore.queueLength} | {syncStore.isOnline ? "Online" : "Offline"} | Attendees: {syncStore.attendeeCount}
      </p>
    {/if}
  </div>

  <!-- Scanner Area -->
  {#if !isNative}
    <div class="rounded-xl overflow-hidden bg-black hide-on-scan">
      <div id="reader" class="w-full"></div>
    </div>
  {:else if !isScannerActive}
    <button
      class="w-full py-8 rounded-xl border-2 border-dashed border-blue-300 bg-blue-50 text-blue-600 font-bold hover:bg-blue-100 transition-colors flex flex-col items-center gap-2"
      onclick={startScanner}
      disabled={cacheBlocked}>
      <span class="text-3xl">📷</span>
      Tap to Scan with Camera
    </button>
  {/if}

  <!-- Manual Entry Simulation -->
  <div class="flex flex-col gap-4 hide-on-scan transition-opacity">
    <div class="flex gap-2">
      <input
        type="text"
        bind:value={ticketCode}
        placeholder="Enter ticket code..."
        class="flex-1 px-4 py-3 rounded-lg border border-gray-300 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
        onkeydown={e => e.key === "Enter" && handleScan(ticketCode)} />
      <button
        class="bg-gray-200 text-gray-700 px-4 py-3 rounded-lg font-medium hover:bg-gray-300 transition-colors"
        onclick={handleLookup}
        disabled={!ticketCode || cacheBlocked}>
        🔍
      </button>
      <button
        class="bg-blue-600 text-white px-6 py-3 rounded-lg font-medium hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        onclick={() => handleScan(ticketCode)}
        disabled={!ticketCode || isProcessing || cacheBlocked}>
        {isProcessing ? "..." : "Scan"}
      </button>
    </div>

    {#if lookupResult}
      <div class="bg-white p-4 rounded-lg shadow border border-gray-200 animate-in fade-in slide-in-from-top-2">
        <div class="flex justify-between items-start mb-2">
          <div>
            <h3 class="font-bold text-lg">{lookupResult.first_name} {lookupResult.last_name}</h3>
            <p class="text-sm text-gray-500">{lookupResult.ticket_code}</p>
          </div>
          <span
            class="px-2 py-1 text-xs font-bold rounded {lookupResult.payment_status === 'paid'
              ? 'bg-green-100 text-green-800'
              : 'bg-yellow-100 text-yellow-800'}">
            {lookupResult.payment_status.toUpperCase()}
          </span>
        </div>
        <div class="grid grid-cols-2 gap-2 text-sm mt-2">
          <div class="bg-gray-50 p-2 rounded">
            <span class="block text-xs text-gray-500">Status</span>
            <span class="font-medium">{lookupResult.is_currently_inside ? "Inside" : "Outside"}</span>
          </div>
          <div class="bg-gray-50 p-2 rounded">
            <span class="block text-xs text-gray-500">Remaining</span>
            <span class="font-medium">{lookupResult.checkins_remaining}</span>
          </div>
        </div>
        <button
          class="w-full mt-3 bg-blue-600 text-white py-2 rounded-lg font-medium hover:bg-blue-700"
          onclick={() => handleScan(lookupResult!.ticket_code)}>
          Confirm {direction === "in" ? "Check In" : "Check Out"}
        </button>
      </div>
    {/if}
  </div>
</div>

<style>
  /* Make background transparent when scanner is active */
  :global(body.scanner-active) {
    background: transparent !important;
    --scanner-active: 1;
  }
  :global(html) {
    background: #f3f4f6; /* Match default bg */
  }
  :global(body.scanner-active) .scan-page-container {
    background: transparent !important;
  }
  /* Hide everything except the overlay controls when scanning */
  :global(body.scanner-active) .hide-on-scan {
    opacity: 0;
    pointer-events: none;
  }
</style>
