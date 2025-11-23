# FastCheck Mobile

Mobile client for FastCheck built with SvelteKit. Use the standard Vite and SvelteKit commands for development and builds.

## Development

```sh
npm install
npm run dev
# or
npm run build && npm run preview
```

## Sync store

The sync logic is centralized in `src/lib/stores/sync.ts`, which exports a single `syncStore` instance. Import that singleton in router pages instead of creating new stores to avoid duplicate network event listeners.
