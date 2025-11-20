<script lang="ts">
  import { processScan, type ScanResult } from '$lib/logic/scanner';
  import { auth } from '$lib/stores/auth';
  import { syncStore } from '$lib/stores/sync.svelte';
  import type { ScanDirection } from '$lib/types';

  // State
  let direction = $state<ScanDirection>('in');
  let ticketCode = $state('');
  let lastResult = $state<ScanResult | null>(null);
  let isProcessing = $state(false);

  // Derived
  let statusColor = $derived(
    !lastResult 
      ? 'bg-gray-100 text-gray-500' 
      : lastResult.success 
        ? 'bg-green-100 text-green-800 border-green-200' 
        : 'bg-red-100 text-red-800 border-red-200'
  );

  async function handleScan() {
    if (!ticketCode.trim() || isProcessing) return;
    
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

      const result = await processScan(ticketCode, direction, eventId);
      lastResult = result;
      
      if (result.success) {
        ticketCode = ''; // Clear input on success
      }
    } catch (e) {
      console.error(e);
      lastResult = {
        success: false,
        message: 'Unexpected error processing scan',
        error_code: 'UNKNOWN_ERROR'
      };
    } finally {
      isProcessing = false;
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

  <!-- Scanner Placeholder -->
  <div class="aspect-square bg-black rounded-xl overflow-hidden relative">
    <div class="absolute inset-0 flex items-center justify-center text-white/50">
      <p>Scanner Camera View</p>
    </div>
    <!-- Overlay -->
    <div class="absolute inset-0 border-2 border-white/30 m-8 rounded-lg pointer-events-none"></div>
  </div>

  <!-- Manual Entry Simulation -->
  <div class="flex gap-2">
    <input
      type="text"
      bind:value={ticketCode}
      placeholder="Enter ticket code..."
      class="flex-1 px-4 py-3 rounded-lg border border-gray-300 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 outline-none"
      onkeydown={(e) => e.key === 'Enter' && handleScan()}
    />
    <button
      class="bg-blue-600 text-white px-6 py-3 rounded-lg font-medium hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
      onclick={handleScan}
      disabled={!ticketCode || isProcessing}
    >
      {isProcessing ? '...' : 'Scan'}
    </button>
  </div>
</div>
