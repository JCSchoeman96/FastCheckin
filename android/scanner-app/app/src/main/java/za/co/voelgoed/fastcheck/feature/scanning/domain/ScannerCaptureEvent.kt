package za.co.voelgoed.fastcheck.feature.scanning.domain

/**
 * A single capture fact emitted by a scanner input source.
 *
 * This models only what the source itself knows at capture time: the decoded value,
 * when it was captured, and basic source metadata. It intentionally excludes any
 * queueing, session, or business-rule fields such as direction, operator, or entrance.
 */
data class ScannerCaptureEvent(
    val rawValue: String,
    val capturedAtEpochMillis: Long,
    val sourceType: ScannerSourceType,
    val sourceId: String?
)

