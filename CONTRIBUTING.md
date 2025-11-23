# Contributing to FastCheck

## Code Formatting

We use `mix format` to ensure consistent code style across the project.

### Configuration
The formatting rules are defined in `.formatter.exs`. We enforce:
- Standard Elixir formatting.
- Phoenix HEEx formatting (including `attr`, `slot`, `embed_templates` with parentheses).
- Import of dependencies configuration (`ecto`, `phoenix`, etc).

### Workflow
Before committing, please run:
```bash
mix format
```

### CI/CD
The CI pipeline runs `mix format --check-formatted` and will fail if there are unformatted files.
