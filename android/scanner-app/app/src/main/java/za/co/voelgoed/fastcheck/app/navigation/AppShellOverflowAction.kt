package za.co.voelgoed.fastcheck.app.navigation

enum class AppShellOverflowAction(
    val label: String
) {
    Support(label = "Support"),
    Logout(label = "Logout");

    companion object {
        val overflowActions: List<AppShellOverflowAction> =
            listOf(Support, Logout)
    }
}
