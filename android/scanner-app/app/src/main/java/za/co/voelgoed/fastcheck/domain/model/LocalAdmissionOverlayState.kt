package za.co.voelgoed.fastcheck.domain.model

enum class LocalAdmissionOverlayState {
    PENDING_LOCAL,
    CONFIRMED_LOCAL_UNSYNCED,
    CONFLICT_DUPLICATE,
    CONFLICT_REJECTED;

    companion object {
        val activeStates: Set<LocalAdmissionOverlayState> =
            entries.toSet()

        val unresolvedStates: Set<LocalAdmissionOverlayState> =
            activeStates

        val conflictStates: Set<LocalAdmissionOverlayState> =
            setOf(CONFLICT_DUPLICATE, CONFLICT_REJECTED)

        val removableAfterSyncStates: Set<LocalAdmissionOverlayState> =
            setOf(CONFIRMED_LOCAL_UNSYNCED)
    }
}
