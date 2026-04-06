package za.co.voelgoed.fastcheck.feature.scanning

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerSourceState
import za.co.voelgoed.fastcheck.feature.scanning.ui.ScanningViewModel
import za.co.voelgoed.fastcheck.feature.scanning.usecase.CaptureHandoffResult

class ScanningViewModelRecreationTest {
    private val acceptedResult =
        CaptureHandoffResult.Accepted(
            attendeeId = 7L,
            displayName = "Jane Doe",
            ticketCode = "VG-007",
            idempotencyKey = "idem-7",
            scannedAt = "2026-04-06T10:00:00Z"
        )

    private sealed class Event {
        data class SourceState(val phase: String, val state: ScannerSourceState) : Event()
        data class Feedback(val phase: String, val result: CaptureHandoffResult) : Event()
    }

    @Test
    fun retainedViewModelDetachesFromOldBindingAndAttachesToNewBinding() = runTest {
        val viewModel = ScanningViewModel()
        val events = mutableListOf<Event>()

        val oldBindingState = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)
        val newBindingState = MutableStateFlow<ScannerSourceState>(ScannerSourceState.Idle)

        // Phase A: old binding attached and active.
        val oldJob = launch {
            oldBindingState.collect { state ->
                events += Event.SourceState("old", state)
                viewModel.onSourceStateChanged(state)
            }
        }

        fun emitOldCapture() {
            events += Event.Feedback("old", acceptedResult)
            viewModel.onCaptureHandoffResult(acceptedResult)
        }

        fun emitNewCapture() {
            events += Event.Feedback("new", acceptedResult)
            viewModel.onCaptureHandoffResult(acceptedResult)
        }

        // Phase A: old binding produces state and one feedback.
        oldBindingState.value = ScannerSourceState.Starting
        oldBindingState.value = ScannerSourceState.Ready
        advanceUntilIdle()
        emitOldCapture()
        advanceUntilIdle()

        val eventsAfterOld = events.toList()

        // Phase B: cancel old collector, then emit stale old events.
        oldJob.cancel()

        val staleOldState = ScannerSourceState.Error("stale-old")
        oldBindingState.value = staleOldState
        // Record the input stimulus, but any observed outputs would use a different phase.
        events += Event.SourceState("old-stimulus", staleOldState)
        advanceUntilIdle()

        // Checkpoint: no new observed old outputs after cancellation.
        val observedOldOutputs =
            events.filter {
                (it is Event.SourceState && it.phase == "old") ||
                    (it is Event.Feedback && it.phase == "old")
            }
        val expectedOldOutputs =
            eventsAfterOld.filter {
                (it is Event.SourceState && it.phase == "old") ||
                    (it is Event.Feedback && it.phase == "old")
            }
        assertThat(observedOldOutputs).containsExactlyElementsIn(expectedOldOutputs)

        // Phase D: attach new binding and emit new events.
        val newJob = launch {
            newBindingState.collect { state ->
                events += Event.SourceState("new", state)
                viewModel.onSourceStateChanged(state)
            }
        }

        newBindingState.value = ScannerSourceState.Starting
        newBindingState.value = ScannerSourceState.Ready
        advanceUntilIdle()

        emitNewCapture()
        emitNewCapture()
        advanceUntilIdle()

        // New binding must contribute exactly two feedback events.
        val newFeedbackEvents =
            events.filterIsInstance<Event.Feedback>().filter { it.phase == "new" }
        assertThat(newFeedbackEvents).hasSize(2)

        // Phase E: emit another stale old event after new is attached; it must still be ignored.
        val eventsBeforeSecondStaleOld = events.toList()

        val secondStaleOldState = ScannerSourceState.Error("stale-old-2")
        oldBindingState.value = secondStaleOldState
        events += Event.SourceState("old-stimulus-2", secondStaleOldState)
        advanceUntilIdle()

        val observedOldStaleOutputs =
            events.filterIsInstance<Event.SourceState>().filter { it.phase == "old-stale" } +
                events.filterIsInstance<Event.Feedback>().filter { it.phase == "old-stale" }

        assertThat(observedOldStaleOutputs).isEmpty()
        assertThat(events).containsExactlyElementsIn(eventsBeforeSecondStaleOld + events.last())

        newJob.cancel()
    }
}
