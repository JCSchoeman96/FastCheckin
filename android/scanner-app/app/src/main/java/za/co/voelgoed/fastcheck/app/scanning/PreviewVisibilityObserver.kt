package za.co.voelgoed.fastcheck.app.scanning

/**
 * Tracks preview visibility transitions and fires the callback only on a
 * false-to-true edge. This avoids noisy repeated resyncs on every layout
 * pass while still catching the moment the preview first becomes visible.
 *
 * Callers must invoke [onVisibilityEvaluated] both at registration time
 * (initial reconciliation) and on subsequent layout callbacks to guarantee
 * the transition is never missed.
 */
class PreviewVisibilityObserver(
    private val onBecameVisible: () -> Unit
) {
    private var wasVisible: Boolean = false

    fun onVisibilityEvaluated(isVisible: Boolean) {
        if (isVisible && !wasVisible) {
            onBecameVisible()
        }
        wasVisible = isVisible
    }
}
