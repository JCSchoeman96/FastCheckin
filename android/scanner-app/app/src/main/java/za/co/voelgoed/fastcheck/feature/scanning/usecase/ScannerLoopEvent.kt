package za.co.voelgoed.fastcheck.feature.scanning.usecase

import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCandidate
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerResult

sealed interface ScannerLoopEvent {
    data class CandidateAccepted(
        val candidate: ScannerCandidate
    ) : ScannerLoopEvent

    data class ProcessingStarted(
        val candidate: ScannerCandidate
    ) : ScannerLoopEvent

    data class ImmediateResult(
        val result: ScannerResult
    ) : ScannerLoopEvent
}
