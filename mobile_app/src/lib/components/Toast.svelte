<script lang="ts">
  import { notifications } from "$lib/stores/notifications";
  import { fly } from "svelte/transition";
  import { flip } from "svelte/animate";
</script>

<div class="fixed top-4 right-4 z-50 flex flex-col gap-2 max-w-sm">
  {#each $notifications as notification (notification.id)}
    <div
      animate:flip={{ duration: 200 }}
      in:fly={{ x: 300, duration: 200 }}
      out:fly={{ x: 300, duration: 200 }}
      class="rounded-lg shadow-lg px-4 py-3 flex items-start gap-3 {notification.type === 'error'
        ? 'bg-red-600 text-white'
        : notification.type === 'success'
          ? 'bg-green-600 text-white'
          : notification.type === 'warning'
            ? 'bg-yellow-600 text-white'
            : 'bg-blue-600 text-white'}">
      <div class="flex-1">
        <p class="text-sm font-medium">{notification.message}</p>

        {#if notification.actions?.length}
          <div class="mt-2 flex flex-wrap gap-2">
            {#each notification.actions as action}
              <button
                class="text-xs font-semibold rounded bg-white/20 px-2 py-1 hover:bg-white/30"
                on:click={() => {
                  action.handler?.();
                  notifications.remove(notification.id);
                }}>
                {action.label}
              </button>
            {/each}
          </div>
        {/if}
      </div>
      <button
        on:click={() => notifications.remove(notification.id)}
        class="text-white/80 hover:text-white"
        aria-label="Dismiss">
        <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>
  {/each}
</div>
