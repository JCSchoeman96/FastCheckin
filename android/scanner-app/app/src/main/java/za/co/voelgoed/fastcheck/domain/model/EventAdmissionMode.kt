package za.co.voelgoed.fastcheck.domain.model

/**
 * Server-driven admission semantics for the authenticated event.
 */
enum class EventAdmissionMode {
    SESSION,
    TURNSTILE;

    companion object {
        fun fromApiValue(value: String?): EventAdmissionMode =
            when (value?.trim()?.lowercase()) {
                "turnstile" -> TURNSTILE
                else -> SESSION
            }
    }
}
