package za.co.voelgoed.fastcheck.data.local

import androidx.room.Entity

@Entity(
    tableName = "recent_flush_outcomes",
    primaryKeys = ["eventId", "outcomeOrder"]
)
data class RecentFlushOutcomeEntity(
    val eventId: Long,
    val outcomeOrder: Int,
    val idempotencyKey: String,
    val ticketCode: String,
    val outcome: String,
    val message: String,
    val reasonCode: String? = null,
    val completedAt: String
)
