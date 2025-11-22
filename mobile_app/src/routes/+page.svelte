<script lang="ts">
  import { goto } from "$app/navigation";
  import { auth } from "$lib/stores/auth";
  import { onMount } from "svelte";

  let eventId = "";
  let deviceName = "";
  let credential = "";
  let formError: string | null = null;

  onMount(() => {
    if ($auth.isAuthenticated) {
      goto("/scan");
    }
  });

  async function handleSubmit(event: Event) {
    event.preventDefault();
    formError = null;

    const success = await auth.login(eventId.trim(), deviceName.trim(), credential.trim());

    if (success) {
      goto("/scan");
      return;
    }

    formError = $auth.error || "Login failed. Please try again.";
  }
</script>

<div class="flex min-h-screen items-center justify-center bg-slate-50 px-4 py-12">
  <div class="w-full max-w-md rounded-2xl bg-white p-8 shadow-lg">
    <div class="mb-6 text-center">
      <h1 class="text-2xl font-bold text-slate-900">FastCheck Mobile</h1>
      <p class="mt-2 text-sm text-slate-600">Enter your event credentials to start scanning.</p>
    </div>

    <form class="space-y-4" on:submit={handleSubmit}>
      <label class="block text-sm font-medium text-slate-700" for="event-id">Event ID</label>
      <input
        id="event-id"
        class="w-full rounded-lg border border-slate-300 px-4 py-2 text-sm text-slate-900 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200"
        type="number"
        bind:value={eventId}
        required
        placeholder="123"
      />

      <label class="block text-sm font-medium text-slate-700" for="device-name">Device name</label>
      <input
        id="device-name"
        class="w-full rounded-lg border border-slate-300 px-4 py-2 text-sm text-slate-900 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200"
        type="text"
        bind:value={deviceName}
        required
        placeholder="Front Gate Scanner"
      />

      <label class="block text-sm font-medium text-slate-700" for="credential">Mobile access code</label>
      <input
        id="credential"
        class="w-full rounded-lg border border-slate-300 px-4 py-2 text-sm text-slate-900 focus:border-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-200"
        type="password"
        bind:value={credential}
        required
        placeholder="••••••"
      />

      {#if formError}
        <p class="rounded-lg bg-red-50 px-4 py-2 text-sm text-red-700">{formError}</p>
      {/if}
      {#if $auth.isLoading}
        <p class="text-sm text-slate-600">Signing in...</p>
      {/if}

      <button
        type="submit"
        class="w-full rounded-lg bg-blue-600 px-4 py-2 text-sm font-semibold text-white shadow hover:bg-blue-500 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2 disabled:cursor-not-allowed disabled:bg-blue-300"
        disabled={$auth.isLoading}
      >
        {$auth.isLoading ? "Signing in..." : "Sign in"}
      </button>
    </form>
  </div>
</div>
