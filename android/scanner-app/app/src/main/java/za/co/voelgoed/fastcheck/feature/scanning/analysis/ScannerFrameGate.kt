package za.co.voelgoed.fastcheck.feature.scanning.analysis

import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

@Singleton
class ScannerFrameGate @Inject constructor() {
    private val lock = Any()
    private var locked = false

    fun tryAdmit(detection: ScannerDetection): Boolean =
        synchronized(lock) {
            if (locked) {
                false
            } else {
                locked = true
                true
            }
        }

    fun release() {
        synchronized(lock) {
            locked = false
        }
    }

    fun reset() = release()
}
