<script lang="ts">
  import { processScan, type ScanResult } from '$lib/logic/scanner';
  import { auth } from '$lib/stores/auth';
  import { syncStore } from '$lib/stores/sync.svelte';
  import type { ScanDirection, Attendee } from '$lib/types';
  import { Html5QrcodeScanner, Html5QrcodeSupportedFormats } from 'html5-qrcode';
  import { onMount, onDestroy } from 'svelte';
  import { db } from '$lib/db';

  // State
  let direction = $state<ScanDirection>('in');
  let ticketCode = $state('');
  let lastResult = $state<ScanResult | null>(null);
  let isProcessing = $state(false);
  let scanner: Html5QrcodeScanner | null = null;

  // Derived
  let statusColor = $derived(
    !lastResult 
      ? 'bg-gray-100 text-gray-500 border-gray-300' 
      : lastResult.success 
        ? 'bg-green-500 text-white border-green-600 shadow-lg scale-105' 
        : 'bg-red-500 text-white border-red-600 shadow-lg scale-105'
  );

  onMount(() => {
    startScanner();
  });

  onDestroy(() => {
    if (scanner) {
      scanner.clear().catch(console.error);
    }
  });

  function startScanner() {
    const config = {
      fps: 10,
      qrbox: { width: 250, height: 250 },
      aspectRatio: 1.0,
      formatsToSupport: [ Html5QrcodeSupportedFormats.QR_CODE ]
    };

    scanner = new Html5QrcodeScanner("reader", config, false);
    scanner.render(onScanSuccess, onScanFailure);
  }

  function onScanSuccess(decodedText: string, decodedResult: any) {
    // Debounce/Throttle could be added here if needed, but handleScan checks isProcessing
    handleScan(decodedText);
  }

  function onScanFailure(error: any) {
    // console.warn(`Code scan error = ${error}`);
  }

  async function handleScan(code: string = ticketCode) {
    if (!code.trim() || isProcessing) return;
    
    isProcessing = true;
    lastResult = null;

    try {
      const eventId = $auth.event_id;
      if (!eventId) {
        lastResult = {
          success: false,
          message: 'No event selected. Please login.',
          error_code: 'NO_EVENT'
        };
        return;
      }

      const result = await processScan(code, direction, eventId);
      lastResult = result;
      
      if (result.success) {
        ticketCode = ''; // Clear input on success
        triggerFeedback(true);
      } else {
        triggerFeedback(false);
      }
    } catch (e) {
      console.error(e);
      lastResult = {
        success: false,
        message: 'Unexpected error processing scan',
        error_code: 'UNKNOWN_ERROR'
      };
      triggerFeedback(false);
    } finally {
      // Add a small delay before allowing next scan to prevent double-scans
      setTimeout(() => {
        isProcessing = false;
      }, 1000);
    }
  }

  function triggerFeedback(success: boolean) {
    // Haptic Feedback
    if (navigator.vibrate) {
      if (success) {
        navigator.vibrate(200); // Single short buzz
      } else {
        navigator.vibrate([100, 50, 100, 50, 100]); // Error pattern (buzz-pause-buzz...)
      }
    }
  }

  function toggleDirection() {
    direction = direction === 'in' ? 'out' : 'in';
    lastResult = null; // Clear result on direction change
  }
</script>

<div class="flex flex-col h-full max-w-md mx-auto p-4 space-y-6">
  <!-- Header / Direction Toggle -->
  <div class="flex rounded-lg bg-gray-200 p-1">
    <button
      class="flex-1 py-3 text-sm font-medium rounded-md transition-all {direction === 'in' ? 'bg-white shadow text-blue-600' : 'text-gray-500 hover:text-gray-700'}"
      onclick={() => direction = 'in'}
    >
      Check In
    </button>
    <button
      class="flex-1 py-3 text-sm font-medium rounded-md transition-all {direction === 'out' ? 'bg-white shadow text-blue-600' : 'text-gray-500 hover:text-gray-700'}"
      onclick={() => direction = 'out'}
    >
      Check Out
    </button>
  </div>

  <!-- Status Panel -->
  <div class="flex flex-col items-center justify-center p-8 rounded-xl border-2 border-dashed min-h-[200px] transition-colors {statusColor}">
    {#if lastResult}
      <div class="text-4xl mb-2">
        {lastResult.success ? '✅' : '❌'}
      </div>
      <h2 class="text-2xl font-bold text-center mb-1">
        {lastResult.message}
      </h2>
      {#if lastResult.attendee}
        <div class="text-sm opacity-75 text-center mt-2">
          {lastResult.attendee.first_name} {lastResult.attendee.last_name}
          <br>
          <span class="font-mono text-xs">{lastResult.attendee.ticket_code}</span>
        </div>
      {/if}
      {#if lastResult.error_code}
        <div class="mt-2 text-xs font-mono bg-black/10 px-2 py-1 rounded">
          {lastResult.error_code}
        </div>
      {/if}
    {:else}
      <div class="text-4xl mb-2 text-gray-300">📷</div>
      <p class="text-center font-medium">Ready to Scan</p>
      <p class="text-xs text-center mt-1">
        Queue: {syncStore.queueLength} | {syncStore.isOnline ? 'Online' : 'Offline'}
      </p>
    {/if}
  </div>

  <!-- Scanner -->
  <div class="rounded-xl overflow-hidden bg-black">
    <div id="reader" class="w-full"></div>
  </div>

  import { db } from '$lib/db';
  import type { Attendee } from '$lib/types';

  // ... (existing imports)

  // State
  // ... (existing state)
  let lookupResult = $state<Attendee | null>(null);

  // ... (existing derived)

  // ... (existing methods)

  async function handleLookup() {
    if (!ticketCode.trim()) return;
    
    try {
      const eventId = $auth.event_id;
      if (!eventId) return;

      const attendee = await db.attendees
        .where({ event_id: eventId, ticket_code: ticketCode.trim() })
        .first();

      if (attendee) {
        lookupResult = attendee;
        lastResult = null; // Clear previous scan result
      } else {
        lookupResult = null;
        lastResult = {
          success: false,
          message: 'Ticket not found',
          error_code: 'NOT_FOUND'
        };
        triggerFeedback(false);
      }
    } catch (e) {
      console.error(e);
    }
  }

  async function handleScan(code: string = ticketCode) {
    // Clear lookup on scan
    lookupResult = null;
    // ... (rest of existing handleScan)
  }
</script>

<!-- ... (existing HTML) -->

  <!-- Manual Entry Simulation -->
  <div class="flex flex-col gap-4">
    <div class="flex gap-2">
      <input
        type="text"
        bind:value={ticketCode}
        placeholder="Enter ticket code..."
        class="flex-1 px-4 py-3 rounded-lg border border-gray-300 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
        onkeydown={(e) => e.key === 'Enter' && handleScan(ticketCode)}
      />
      <button
        class="bg-gray-200 text-gray-700 px-4 py-3 rounded-lg font-medium hover:bg-gray-300 transition-colors"
        onclick={handleLookup}
        disabled={!ticketCode}
      >
        🔍
      </button>
      <button
        class="bg-blue-600 text-white px-6 py-3 rounded-lg font-medium hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
        onclick={() => handleScan(ticketCode)}
        disabled={!ticketCode || isProcessing}
      >
        {isProcessing ? '...' : 'Scan'}
      </button>
    </div>

    {#if lookupResult}
      <div class="bg-white p-4 rounded-lg shadow border border-gray-200 animate-in fade-in slide-in-from-top-2">
        <div class="flex justify-between items-start mb-2">
          <div>
            <h3 class="font-bold text-lg">{lookupResult.first_name} {lookupResult.last_name}</h3>
            <p class="text-sm text-gray-500">{lookupResult.ticket_code}</p>
          </div>
          <span class="px-2 py-1 text-xs font-bold rounded {lookupResult.payment_status === 'paid' ? 'bg-green-100 text-green-800' : 'bg-yellow-100 text-yellow-800'}">
            {lookupResult.payment_status.toUpperCase()}
          </span>
        </div>
        <div class="grid grid-cols-2 gap-2 text-sm mt-2">
          <div class="bg-gray-50 p-2 rounded">
            <span class="block text-xs text-gray-500">Status</span>
            <span class="font-medium">{lookupResult.is_currently_inside ? 'Inside' : 'Outside'}</span>
          </div>
          <div class="bg-gray-50 p-2 rounded">
            <span class="block text-xs text-gray-500">Remaining</span>
            <span class="font-medium">{lookupResult.checkins_remaining}</span>
          </div>
        </div>
        <button
          class="w-full mt-3 bg-blue-600 text-white py-2 rounded-lg font-medium hover:bg-blue-700"
          onclick={() => handleScan(lookupResult!.ticket_code)}
        >
          Confirm {direction === 'in' ? 'Check In' : 'Check Out'}
        </button>
      </div>
    {/if}
  </div>
</div>
