package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

@Entity(
    tableName = "scan_replay_cache",
    indices = [Index(value = ["idempotencyKey"], unique = true)]
)
data class ReplayCacheEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val idempotencyKey: String,
    val status: String,
    val message: String,
    val storedAt: String,
    val terminal: Boolean
)
