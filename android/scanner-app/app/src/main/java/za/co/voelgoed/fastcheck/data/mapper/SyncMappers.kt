package za.co.voelgoed.fastcheck.data.mapper

import za.co.voelgoed.fastcheck.data.local.SyncMetadataEntity
import za.co.voelgoed.fastcheck.data.remote.MobileSyncPayload
import za.co.voelgoed.fastcheck.domain.model.AttendeeSyncStatus

fun MobileSyncPayload.toSyncMetadata(eventId: Long): SyncMetadataEntity =
    SyncMetadataEntity(
        eventId = eventId,
        lastServerTime = server_time,
        lastSuccessfulSyncAt = server_time,
        lastSyncType = sync_type,
        attendeeCount = count
    )

fun SyncMetadataEntity.toDomain(): AttendeeSyncStatus =
    AttendeeSyncStatus(
        eventId = eventId,
        lastServerTime = lastServerTime,
        lastSuccessfulSyncAt = lastSuccessfulSyncAt,
        syncType = lastSyncType,
        attendeeCount = attendeeCount
    )
