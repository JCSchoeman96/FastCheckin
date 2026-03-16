package za.co.voelgoed.fastcheck.feature.scanning.domain

/**
 * Classifies the physical or logical source that is producing scanner captures.
 *
 * This enum is intentionally small and concrete. It does not encode any behaviour or
 * business rules; it is used purely as a label by source adapters and downstream
 * consumers.
 */
enum class ScannerSourceType {
    /**
     * Captures emitted from a camera-based scanner, such as CameraX with ML Kit.
     */
    CAMERA,

    /**
     * Captures emitted from a hardware or software keyboard wedge, typically via HID.
     */
    KEYBOARD_WEDGE,

    /**
     * Captures delivered via broadcast-style mechanisms (for example, Android intents).
     */
    BROADCAST_INTENT
}

