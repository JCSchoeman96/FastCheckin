package za.co.voelgoed.fastcheck.feature.auth

data class AuthUiState(
    val eventIdInput: String = "",
    val credentialInput: String = "",
    val isSubmitting: Boolean = false,
    val sessionSummary: String? = null,
    val errorMessage: String? = null
)
