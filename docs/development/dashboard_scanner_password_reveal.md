# Dashboard: reveal current scanner password

## Purpose

Operators sometimes need the **current** mobile/scanner password for an event (the value stored as `mobile_access_secret_encrypted`) without rotating it. The dashboard provides a **read-only reveal** gated by re-entering the **dashboard admin password**, plus a one-click **Copy** action.

## Where to use it

1. **Event card** — After **Edit / History / Full sync**, use **View password** (disabled if no password is stored).
2. **Edit Event** modal — At the top of the modal (above the main edit fields, including **Mobile access code**), use **Current scanner password** → **Reveal**, confirm with the admin password, then **Copy** or **Hide**.

Rotating the password is unchanged: use **Mobile access code** in the same edit form (leave blank to keep the current value).

## Security notes

- The credential is **decrypted only in the LiveView process** after a successful admin-password check; it is not logged and is not exposed via a dedicated JSON endpoint.
- After reveal, the cleartext exists in the browser DOM (for display and copy). Treat the screen and clipboard as sensitive until the operator clicks **Hide** or closes the modal.
- Repeated wrong admin passwords trigger a **short lockout** per event (defaults: 5 failures within 60 seconds → 60-second lock; tests may override via `Application` env — see `FastCheckWeb.DashboardLive`).

## Training / support

Mention this flow when onboarding admins who configure scanner apps: they can self-serve the current password from the dashboard after authenticating, instead of rotating by mistake.
