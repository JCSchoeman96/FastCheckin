# Semantic UI State Review

- Retained: `PaymentUiState` stays `Paid`, `Pending`, `NotValid`, and `Unknown`; `AttendanceUiState` stays `NotCheckedIn`, `CheckedIn`, `CurrentlyInside`, `CheckedOut`, and `Unknown`.
- Merged: payment `refunded`, `cancelled`, `canceled`, `voided`, and `failed` remain merged into `NotValid`.
- Retained: duplicate scan meaning stays in `ScanUiState`, not `AttendanceUiState`.
- Split: attendance keeps `CheckedIn`, `CurrentlyInside`, and `CheckedOut` distinct because current runtime truth distinguishes them.
- Deferred: finer payment sub-states and any additional attendance sub-states are deferred until runtime truth requires them.
