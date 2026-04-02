package za.co.voelgoed.fastcheck.app.navigation

enum class AppShellOverflowAction(
    val label: String,
    val placeholderMessage: String?
) {
    Preferences(
        label = "Preferences",
        placeholderMessage = "Preferences stays in overflow for now. A real destination is later work."
    ),
    Permissions(
        label = "Permissions",
        placeholderMessage = "Permission recovery stays in overflow for now. A real destination is later work."
    ),
    Diagnostics(
        label = "Diagnostics",
        placeholderMessage = "Diagnostics remains secondary in Phase 9. Richer diagnostics moves later."
    ),
    Logout(
        label = "Logout",
        placeholderMessage = null
    );

    companion object {
        val overflowActions: List<AppShellOverflowAction> =
            listOf(Preferences, Permissions, Diagnostics, Logout)
    }
}
