package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity
import androidx.room.PrimaryKey

@Entity(tableName = "recent_flush_outcomes")
data class RecentFlushOutcomeEntity(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val outcomeOrder: Int,
    val idempotencyKey: String,
    val ticketCode: String,
    val outcome: String,
    val message: String,
    val completedAt: String
)
