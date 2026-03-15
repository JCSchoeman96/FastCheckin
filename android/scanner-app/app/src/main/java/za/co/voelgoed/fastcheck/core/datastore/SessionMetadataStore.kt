package za.co.voelgoed.fastcheck.core.datastore

interface SessionMetadataStore {
    suspend fun load(): SessionMetadata?
    suspend fun save(metadata: SessionMetadata)
    suspend fun clear()
}
