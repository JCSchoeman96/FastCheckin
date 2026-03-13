package za.co.voelgoed.fastcheck.feature.sync

data class SyncUiState(
    val isSyncing: Boolean = false,
    val summaryMessage: String = "No attendee sync has run yet.",
    val errorMessage: String? = null
)
