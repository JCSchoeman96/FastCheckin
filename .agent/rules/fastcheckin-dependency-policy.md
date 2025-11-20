---
trigger: always_on
---

On the backend, prefer the existing Elixir ecosystem (Phoenix, Ecto, etc.). Only add new Hex dependencies when clearly necessary for the mobile API or offline sync.

On the frontend, keep dependencies lean: SvelteKit, Dexie, Capacitor, and a single QR scanning approach are preferred. Avoid stacking multiple UI libraries or scanners.

When adding a dependency, briefly document in comments why it was chosen and what problem it solves.

Do not swap out core frameworks (Phoenix, SvelteKit) in this workspace.