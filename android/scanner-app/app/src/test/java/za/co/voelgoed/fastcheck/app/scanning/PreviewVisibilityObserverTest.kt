package za.co.voelgoed.fastcheck.app.scanning

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class PreviewVisibilityObserverTest {
    @Test
    fun firesCallbackOnFalseToTrueTransition() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(false)
        assertThat(fireCount).isEqualTo(0)

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)
    }

    @Test
    fun doesNotFireOnRepeatedTrueEvaluations() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)
    }

    @Test
    fun doesNotFireOnRepeatedFalseEvaluations() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(false)
        observer.onVisibilityEvaluated(false)

        assertThat(fireCount).isEqualTo(0)
    }

    @Test
    fun doesNotFireOnTrueToFalseTransition() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)

        observer.onVisibilityEvaluated(false)
        assertThat(fireCount).isEqualTo(1)
    }

    @Test
    fun initialReconciliationFiresWhenAlreadyVisible() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(true)

        assertThat(fireCount).isEqualTo(1)
    }

    @Test
    fun initialReconciliationDoesNotFireWhenNotYetVisible() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(false)

        assertThat(fireCount).isEqualTo(0)
    }

    @Test
    fun delayedVisibilityPathFiresOnSecondEvaluation() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(false)
        assertThat(fireCount).isEqualTo(0)

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)
    }

    @Test
    fun firesAgainAfterVisibilityIsLostAndRestored() {
        var fireCount = 0
        val observer = PreviewVisibilityObserver { fireCount++ }

        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(1)

        observer.onVisibilityEvaluated(false)
        observer.onVisibilityEvaluated(true)
        assertThat(fireCount).isEqualTo(2)
    }
}
