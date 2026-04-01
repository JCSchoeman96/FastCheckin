package za.co.voelgoed.fastcheck.core.ticket

/**
 * Contract tests are the source of truth for which surrounding characters are trimmed.
 * This implementation intentionally stays narrow and only removes the proven scanner
 * boundary cases from the start and end of the captured value.
 */
object TicketCodeNormalizer {
    private val boundaryCharacters = charArrayOf(' ', '\t', '\n', '\r')

    fun normalizeOrNull(rawValue: String): String? =
        rawValue.trim(*boundaryCharacters).takeIf { it.isNotBlank() }
}
