package za.co.voelgoed.fastcheck.domain.model

enum class SyncState {
    IDLE,
    SYNCING,
    SYNCED,
    PARTIAL_FAILURE,
    FAILED
}
