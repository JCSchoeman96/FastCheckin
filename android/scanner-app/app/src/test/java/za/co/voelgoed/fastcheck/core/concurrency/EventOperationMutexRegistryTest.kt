package za.co.voelgoed.fastcheck.core.concurrency

import com.google.common.truth.Truth.assertThat
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class EventOperationMutexRegistryTest {
    @Test
    fun sameEventFlushesAreSerialized() = runTest {
        val registry = DefaultEventOperationMutexRegistry()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var secondEntered = false

        val first = async {
            registry.withFlushLock(7L) {
                firstEntered.complete(Unit)
                releaseFirst.await()
            }
        }
        firstEntered.await()
        val second = async {
            registry.withFlushLock(7L) {
                secondEntered = true
            }
        }

        runCurrent()
        assertThat(secondEntered).isFalse()

        releaseFirst.complete(Unit)
        first.await()
        second.await()
        assertThat(secondEntered).isTrue()
    }

    @Test
    fun differentEventFlushesCanRunConcurrently() = runTest {
        val registry = DefaultEventOperationMutexRegistry()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var secondEntered = false

        val first = async {
            registry.withFlushLock(7L) {
                firstEntered.complete(Unit)
                releaseFirst.await()
            }
        }
        firstEntered.await()
        val second = async {
            registry.withFlushLock(8L) {
                secondEntered = true
            }
        }

        runCurrent()
        assertThat(secondEntered).isTrue()

        releaseFirst.complete(Unit)
        first.await()
        second.await()
    }

    @Test
    fun syncAndFlushUseIndependentLocks() = runTest {
        val registry = DefaultEventOperationMutexRegistry()
        val flushEntered = CompletableDeferred<Unit>()
        val releaseFlush = CompletableDeferred<Unit>()
        var syncEntered = false

        val flush = async {
            registry.withFlushLock(7L) {
                flushEntered.complete(Unit)
                releaseFlush.await()
            }
        }
        flushEntered.await()
        val sync = async {
            registry.withSyncLock(7L) {
                syncEntered = true
            }
        }

        runCurrent()
        assertThat(syncEntered).isTrue()

        releaseFlush.complete(Unit)
        flush.await()
        sync.await()
    }

    @Test
    fun sameEventSyncsAreSerializedWhileAnotherEventCanBootstrap() = runTest {
        val registry = DefaultEventOperationMutexRegistry()
        val firstEntered = CompletableDeferred<Unit>()
        val releaseFirst = CompletableDeferred<Unit>()
        var sameEventEntered = false
        var otherEventEntered = false

        val first = async {
            registry.withSyncLock(7L) {
                firstEntered.complete(Unit)
                releaseFirst.await()
            }
        }
        firstEntered.await()
        val sameEvent = async { registry.withSyncLock(7L) { sameEventEntered = true } }
        val otherEvent = async { registry.withSyncLock(8L) { otherEventEntered = true } }

        runCurrent()
        assertThat(sameEventEntered).isFalse()
        assertThat(otherEventEntered).isTrue()

        releaseFirst.complete(Unit)
        first.await()
        sameEvent.await()
        otherEvent.await()
        assertThat(sameEventEntered).isTrue()
    }
}
