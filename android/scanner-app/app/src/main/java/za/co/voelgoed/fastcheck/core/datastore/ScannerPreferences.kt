package za.co.voelgoed.fastcheck.core.datastore

data class ScannerPreferences(
    val selectedEventId: Long? = null,
    val lastSyncCursor: String? = null,
    val operatorName: String = "",
    val diagnosticsEnabled: Boolean = true
)
