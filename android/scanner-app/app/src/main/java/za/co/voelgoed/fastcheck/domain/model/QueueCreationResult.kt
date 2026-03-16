package za.co.voelgoed.fastcheck.domain.model

sealed interface QueueCreationResult {
    data class Enqueued(
        val pendingScan: PendingScan
    ) : QueueCreationResult

    data object ReplaySuppressed : QueueCreationResult

    data object MissingSessionContext : QueueCreationResult

    data object InvalidTicketCode : QueueCreationResult
}
