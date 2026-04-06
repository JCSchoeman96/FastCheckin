package za.co.voelgoed.fastcheck.domain.usecase

import za.co.voelgoed.fastcheck.domain.model.LocalAdmissionDecision
import za.co.voelgoed.fastcheck.domain.model.ScanDirection

interface AdmitScanUseCase {
    suspend fun admit(
        ticketCode: String,
        direction: ScanDirection,
        operatorName: String,
        entranceName: String
    ): LocalAdmissionDecision
}
