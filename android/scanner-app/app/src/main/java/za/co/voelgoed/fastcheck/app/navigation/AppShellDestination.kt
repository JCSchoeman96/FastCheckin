package za.co.voelgoed.fastcheck.app.navigation

enum class AppShellDestination(
    val label: String,
    val compactLabel: String
) {
    Scan(label = "Scan", compactLabel = "S"),
    Search(label = "Search", compactLabel = "F"),
    Event(label = "Event", compactLabel = "E");

    companion object {
        val bottomNavigationDestinations: List<AppShellDestination> =
            listOf(Scan, Search, Event)
    }
}
