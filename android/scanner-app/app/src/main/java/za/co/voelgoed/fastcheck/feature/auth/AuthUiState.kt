package za.co.voelgoed.fastcheck.feature.auth

import za.co.voelgoed.fastcheck.domain.model.ScannerSession

data class AuthUiState(
    val eventIdInput: String = "",
    val credentialInput: String = "",
    val isSubmitting: Boolean = false,
    val sessionSummary: String? = null,
    val errorMessage: String? = null,
    val authenticatedSession: ScannerSession? = null
)
