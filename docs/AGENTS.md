# Documentation Agent Instructions

## Step 7 — Load coding style guidelines for all affected files

| Coding style guide       | Files to load                              |
| ------------------------ | ------------------------------------------ |
| Elixir general           | `elixir_general.md`                        |
| Ash resources            | `ash.md`                                   |
| Ash policies             | `ash.md` + `ash_policies.md`               |
| Phoenix LiveView         | `phoenix_liveview.md`                      |
| HEEx templates           | `heex.md`                                  |
| Tailwind CSS             | `tailwind.md`                              |
| JS/TS guidelines         | `js_guidelines.md`                         |
| Svelte components        | `svelte.md`                                |

When modifying any `policies do` block or any policy helper module (e.g., PlatformPolicy, OrganizationPolicy), you MUST also load and follow `/docs/coding_style/ash_policies.md`. Only Ash 3.x policy DSL is allowed.
