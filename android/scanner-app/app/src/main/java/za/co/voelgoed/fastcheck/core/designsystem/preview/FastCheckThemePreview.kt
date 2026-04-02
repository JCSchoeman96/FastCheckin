package za.co.voelgoed.fastcheck.core.designsystem.preview

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import za.co.voelgoed.fastcheck.core.designsystem.semantic.StatusTone
import za.co.voelgoed.fastcheck.core.designsystem.theme.FastCheckTheme
import za.co.voelgoed.fastcheck.core.designsystem.theme.fastCheck

@Preview(name = "FastCheckTheme", showBackground = true)
@Composable
internal fun FastCheckThemePreview() {
    FastCheckTheme {
        val theme = MaterialTheme.fastCheck

        Surface(
            color = theme.statusRoles.resolve(StatusTone.Success).copy(alpha = 0.12f),
        ) {
            Column(
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(theme.spacing.large),
                verticalArrangement = Arrangement.spacedBy(theme.spacing.small)
            ) {
                Text(
                    text = "FastCheck theme",
                    style = theme.typography.titleLarge,
                    color = theme.colorScheme.onSurface
                )
                Text(
                    text = "Single aggregate access path",
                    style = theme.typography.bodyMedium,
                    color = theme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = "Status tone: ${theme.statusRoles.resolve(StatusTone.Success)}",
                    style = theme.typography.labelMedium,
                    color = theme.statusRoles.resolve(StatusTone.Info)
                )
            }
        }
    }
}
