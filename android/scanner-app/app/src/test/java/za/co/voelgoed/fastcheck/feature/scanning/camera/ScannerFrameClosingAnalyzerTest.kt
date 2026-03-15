package za.co.voelgoed.fastcheck.feature.scanning.camera

import androidx.camera.core.ImageProxy
import com.google.common.truth.Truth.assertThat
import java.lang.reflect.Proxy
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Test

class ScannerFrameClosingAnalyzerTest {
    @Test
    fun analyzeAlwaysClosesFrameAndInvokesHook() {
        val frameClosed = AtomicBoolean(false)
        val imageClosed = AtomicBoolean(false)
        val analyzer =
            ScannerFrameClosingAnalyzer {
                frameClosed.set(true)
            }

        analyzer.analyze(fakeImageProxy(imageClosed))

        assertThat(frameClosed.get()).isTrue()
        assertThat(imageClosed.get()).isTrue()
    }

    private fun fakeImageProxy(imageClosed: AtomicBoolean): ImageProxy =
        Proxy.newProxyInstance(
            ImageProxy::class.java.classLoader,
            arrayOf(ImageProxy::class.java)
        ) { _, method, _ ->
            when (method.name) {
                "close" -> {
                    imageClosed.set(true)
                    null
                }

                "getPlanes" -> emptyArray<ImageProxy.PlaneProxy>()
                "getWidth", "getHeight", "getFormat" -> 0
                "getImage" -> null
                else -> null
            }
        } as ImageProxy
}
