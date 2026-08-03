package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "local_replay_suppression",
    indices = [Index(value = ["eventId", "ticketCode"], unique = true)]
)
data class LocalReplaySuppressionEntity(
    val eventId: Long,
    val ticketCode: String,
    val seenAtEpochMillis: Long,
    @PrimaryKey(autoGenerate = true) val id: Long = 0
)
