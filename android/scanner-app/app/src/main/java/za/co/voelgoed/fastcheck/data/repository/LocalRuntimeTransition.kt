package za.co.voelgoed.fastcheck.data.repository

/**
 * Canonical transition types for Android scanner local runtime retention.
 * These names anchor retention semantics at the repository/session boundary.
 */
enum class LocalRuntimeTransition {
    EXPLICIT_LOGOUT,
    AUTH_EXPIRED,
    SAME_EVENT_RELOGIN,
    CLEAN_EVENT_TRANSITION,
    RESTORED_SESSION_BLOCKED_UNRESOLVED_STATE
}
