package za.co.voelgoed.fastcheck.data.repository

interface ScannerPreferencesStore {
    suspend fun loadOperatorName(): String?
}
