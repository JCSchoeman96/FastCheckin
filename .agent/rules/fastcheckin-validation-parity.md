---
trigger: always_on
---

Client validation rules (for check-in/check-out) must mirror backend domain rules as closely as possible.

Any change to backend rules around allowed statuses, max check-ins, or is_inside semantics must be reflected in the frontend validation module rather than adding separate ad-hoc checks.

Keep all client validation logic in a dedicated, pure module (no side effects) to make it easy to audit and update.

When returning validation messages, use clear language that maps to backend error categories (e.g. “ticket already used”, “ticket not paid”).