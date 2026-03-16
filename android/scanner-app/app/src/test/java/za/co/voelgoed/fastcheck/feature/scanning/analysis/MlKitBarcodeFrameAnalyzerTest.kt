package za.co.voelgoed.fastcheck.feature.scanning.analysis

import androidx.camera.core.ImageProxy
import com.google.common.truth.Truth.assertThat
import com.google.mlkit.vision.common.InputImage
import java.lang.reflect.Proxy
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode

class MlKitBarcodeFrameAnalyzerTest {
    @Test
    fun constructorDependsOnlyOnScannerEngineAndDecodedHandler() {
        val constructorParameterTypes =
            MlKitBarcodeFrameAnalyzer::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes).contains(BarcodeScannerEngine::class.java)
        assertThat(constructorParameterTypes).contains(DecodedBarcodeHandler::class.java)
        assertThat(constructorParameterTypes).doesNotContain(za.co.voelgoed.fastcheck.core.network.PhoenixMobileApi::class.java)
    }

    @Test
    fun closesImageProxyWhenMediaImageMissing() {
        val closeRecorder = CloseRecorder()
        val imageProxy = fakeImageProxy(closeRecorder)
        val analyzer =
            MlKitBarcodeFrameAnalyzer(
                barcodeScannerEngine = NoOpBarcodeScannerEngine(),
                decodedBarcodeHandler = RecordingDecodedBarcodeHandler(),
                appDispatchers = AppDispatchers()
            )

        analyzer.analyze(imageProxy)

        assertThat(closeRecorder.closed).isTrue()
    }

    @Test
    fun ignoresBlankAndNullRawValuesWhileClosingImageProxy() = runTest {
        val closeRecorder = CloseRecorder()
        val imageProxy = fakeImageProxy(closeRecorder)
        val handler = RecordingDecodedBarcodeHandler()
        val analyzer =
            MlKitBarcodeFrameAnalyzer(
                barcodeScannerEngine = NoOpBarcodeScannerEngine(),
                decodedBarcodeHandler = handler,
                appDispatchers = AppDispatchers()
            )

        analyzer.deliverDecodedBarcodes(
            listOf(
                DecodedBarcode(rawValue = " ", capturedAtEpochMillis = 1L),
                DecodedBarcode(rawValue = null, capturedAtEpochMillis = 2L)
            ),
            imageProxy
        )

        assertThat(closeRecorder.closed).isTrue()
        assertThat(handler.decodedValues).isEmpty()
    }

    @Test
    fun preservesNonBlankWhitespaceSurroundedValuesExactly() = runTest {
        val closeRecorder = CloseRecorder()
        val imageProxy = fakeImageProxy(closeRecorder)
        val handler = RecordingDecodedBarcodeHandler()
        val analyzer =
            MlKitBarcodeFrameAnalyzer(
                barcodeScannerEngine = NoOpBarcodeScannerEngine(),
                decodedBarcodeHandler = handler,
                appDispatchers = AppDispatchers()
            )

        analyzer.deliverDecodedBarcodes(
            listOf(
                DecodedBarcode(rawValue = "   ", capturedAtEpochMillis = 0L),
                DecodedBarcode(rawValue = "  VG-101  ", capturedAtEpochMillis = 1L)
            ),
            imageProxy
        )

        handler.awaitDecoded()
        assertThat(closeRecorder.closed).isTrue()
        assertThat(handler.decodedValues).containsExactly("  VG-101  ")
    }

    @Test
    fun preservesControlWhitespaceValuesExactlyWhenAdmitted() = runTest {
        val closeRecorder = CloseRecorder()
        val imageProxy = fakeImageProxy(closeRecorder)
        val handler = RecordingDecodedBarcodeHandler()
        val analyzer =
            MlKitBarcodeFrameAnalyzer(
                barcodeScannerEngine = NoOpBarcodeScannerEngine(),
                decodedBarcodeHandler = handler,
                appDispatchers = AppDispatchers()
            )

        analyzer.deliverDecodedBarcodes(
            listOf(
                DecodedBarcode(rawValue = "   ", capturedAtEpochMillis = 0L),
                DecodedBarcode(rawValue = "\tCODE\n", capturedAtEpochMillis = 2L)
            ),
            imageProxy
        )

        handler.awaitDecoded()
        assertThat(closeRecorder.closed).isTrue()
        assertThat(handler.decodedValues).containsExactly("\tCODE\n")
    }

    private class NoOpBarcodeScannerEngine : BarcodeScannerEngine {
        override fun process(
            image: InputImage,
            onSuccess: (List<DecodedBarcode>) -> Unit,
            onFailure: (Exception) -> Unit
        ) = Unit
    }

    private class RecordingDecodedBarcodeHandler : DecodedBarcodeHandler {
        private val latch = CountDownLatch(1)
        val decodedValues = mutableListOf<String>()

        override suspend fun onDecoded(rawValue: String) {
            decodedValues += rawValue
            latch.countDown()
        }

        fun awaitDecoded(timeoutMillis: Long = 1_000) {
            val completed = latch.await(timeoutMillis, TimeUnit.MILLISECONDS)
            check(completed) { "Timed out waiting for decoded barcode" }
        }
    }

    private class CloseRecorder {
        var closed = false
    }

    private fun fakeImageProxy(closeRecorder: CloseRecorder): ImageProxy =
        Proxy.newProxyInstance(
            ImageProxy::class.java.classLoader,
            arrayOf(ImageProxy::class.java)
        ) { _, method, _ ->
            when (method.name) {
                "close" -> {
                    closeRecorder.closed = true
                    Unit
                }

                "getImage" -> null
                "getImageInfo" ->
                    Proxy.newProxyInstance(
                        ImageProxy::class.java.classLoader,
                        arrayOf(androidx.camera.core.ImageInfo::class.java)
                    ) { _, imageInfoMethod, _ ->
                        when (imageInfoMethod.name) {
                            "getRotationDegrees" -> 0
                            "getTimestamp" -> 0L
                            "getTagBundle" -> androidx.camera.core.impl.TagBundle.emptyBundle()
                            "populateExifData" -> Unit
                            else -> null
                        }
                    }

                "getPlanes" -> emptyArray<ImageProxy.PlaneProxy>()
                "getCropRect" -> android.graphics.Rect()
                "getFormat", "getHeight", "getWidth" -> 0
                "setCropRect" -> Unit
                else -> null
            }
        } as ImageProxy
}
