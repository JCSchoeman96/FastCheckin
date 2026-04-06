/**
 * Operator-facing recovery actions on the Event destination. Relogin is only surfaced
 * when auth-expired blocks uploads with queued work (see presenters).
 */
package za.co.voelgoed.fastcheck.feature.event.model

enum class EventOperatorAction {
    ManualSync,
    RetryUpload,
    Relogin
}

data class EventOperatorActionUiModel(
    val label: String,
    val action: EventOperatorAction
)
