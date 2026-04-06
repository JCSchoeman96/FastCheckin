package za.co.voelgoed.fastcheck.feature.event

import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.feature.event.model.EventOperatorActionUiModel

data class EventDestinationUiState(
    val headerTitle: String,
    val headerSubtitle: String,
    val statusChip: EventStatusChipUiModel,
    val statusMessage: String,
    val attentionBanner: EventBannerUiModel? = null,
    val operatorActions: List<EventOperatorActionUiModel> = emptyList(),
    val attendeeSection: EventSectionUiModel,
    val queueSection: EventSectionUiModel,
    val activitySection: EventSectionUiModel
)

data class EventStatusChipUiModel(
    val text: String,
    val tone: StatusTone
)

data class EventBannerUiModel(
    val title: String,
    val message: String,
    val tone: StatusTone
)

data class EventSectionUiModel(
    val title: String,
    val supportingText: String,
    val metrics: List<EventMetricUiModel>
)

data class EventMetricUiModel(
    val label: String,
    val value: String
)
