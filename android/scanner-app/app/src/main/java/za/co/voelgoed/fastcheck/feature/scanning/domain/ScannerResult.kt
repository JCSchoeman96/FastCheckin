package za.co.voelgoed.fastcheck.feature.scanning.domain

sealed interface ScannerResult {
    val candidate: ScannerCandidate?

    data class QueuedLocally(
        override val candidate: ScannerCandidate
    ) : ScannerResult

    data class ReplaySuppressed(
        override val candidate: ScannerCandidate
    ) : ScannerResult

    data class MissingSessionContext(
        override val candidate: ScannerCandidate
    ) : ScannerResult

    data class InvalidTicketCode(
        override val candidate: ScannerCandidate
    ) : ScannerResult

    data class InitializationFailure(
        val message: String?
    ) : ScannerResult {
        override val candidate: ScannerCandidate? = null
    }
}
