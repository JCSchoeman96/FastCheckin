package za.co.voelgoed.fastcheck.data.repository

/**
 * Attendee sync execution mode for the Phoenix mobile attendees endpoint.
 *
 * Incremental uses the stored server boundary; full reconcile clears local event scope first.
 */
enum class AttendeeSyncMode {
    INCREMENTAL,
    FULL_RECONCILE
}
