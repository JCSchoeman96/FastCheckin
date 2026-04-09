package za.co.voelgoed.fastcheck.app.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Event
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Search
import androidx.compose.ui.graphics.vector.ImageVector

enum class AppShellDestination(
    val label: String,
    val icon: ImageVector
) {
    Scan(label = "Scan", icon = Icons.Outlined.QrCodeScanner),
    Search(label = "Search", icon = Icons.Outlined.Search),
    Event(label = "Event", icon = Icons.Outlined.Event);

    companion object {
        val bottomNavigationDestinations: List<AppShellDestination> =
            listOf(Scan, Search, Event)
    }
}
