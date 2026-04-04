package za.co.voelgoed.fastcheck.feature.support

data class SupportDiagnosticsUiState(
    val sections: List<SupportDiagnosticsSectionUiState>
)

data class SupportDiagnosticsSectionUiState(
    val title: String,
    val items: List<SupportDiagnosticsItemUiState>
)

data class SupportDiagnosticsItemUiState(
    val label: String,
    val value: String
)
