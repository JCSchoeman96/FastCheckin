package za.co.voelgoed.fastcheck.feature.scanning.analysis

import androidx.camera.core.ImageProxy
import com.google.common.truth.Truth.assertThat
import com.google.mlkit.vision.common.InputImage
import java.lang.reflect.Proxy
import kotlinx.coroutines.test.runTest
import org.junit.Test
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.domain.DecodedBarcode
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerDetection

class MlKitBarcodeFrameAnalyzerTest {
    @Test
    fun constructorDependsOnlyOnScannerEngineGateAndDecodedHandler() {
        val constructorParameterTypes =
            MlKitBarcodeFrameAnalyzer::class.java.declaredConstructors.single().parameterTypes.toList()

        assertThat(constructorParameterTypes).contains(BarcodeScannerEngine::class.java)
        assertThat(constructorParameterTypes).contains(ScannerFrameGate::class.java)
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
                scannerFrameGate = ScannerFrameGate(),
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
                scannerFrameGate = ScannerFrameGate(),
                decodedBarcodeHandler = handler,
                appDispatchers = AppDispatchers()
            )

        analyzer.deliverDetections(
            listOf(
                ScannerDetection(rawValue = "VG-101", bounds = null, format = 1, capturedAtEpochMillis = 1L),
                ScannerDetection(rawValue = "VG-102", bounds = null, format = 1, capturedAtEpochMillis = 2L)
            ),
            imageProxy
        )

        assertThat(closeRecorder.closed).isTrue()
        assertThat(handler.decodedValues).containsExactly(DecodedBarcode(rawValue = "VG-101", capturedAtEpochMillis = 1L))
    }

    @Test
    fun sourceUsesZeroCopyMediaImagePathWithoutBitmapConversion() {
        val analyzerFile =
            sequenceOf(
                java.io.File("src/main/java/za/co/voelgoed/fastcheck/feature/scanning/analysis/MlKitBarcodeFrameAnalyzer.kt"),
                java.io.File("app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/analysis/MlKitBarcodeFrameAnalyzer.kt"),
                java.io.File("../app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/analysis/MlKitBarcodeFrameAnalyzer.kt"),
                java.io.File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/analysis/MlKitBarcodeFrameAnalyzer.kt")
            ).firstOrNull { it.exists() }
                ?: error("Could not locate MlKitBarcodeFrameAnalyzer source.")
        val sourceText = analyzerFile.readText()

        assertThat(sourceText).contains("InputImage.fromMediaImage")
        assertThat(sourceText).doesNotContain("Bitmap")
    }

    private class NoOpBarcodeScannerEngine : BarcodeScannerEngine {
        override fun process(
            image: InputImage,
            onSuccess: (List<ScannerDetection>) -> Unit,
            onFailure: (Exception) -> Unit
        ) = Unit
    }

    private class RecordingDecodedBarcodeHandler : DecodedBarcodeHandler {
        val decodedValues = mutableListOf<DecodedBarcode>()

        override suspend fun onDecoded(decodedBarcode: DecodedBarcode) {
            decodedValues += decodedBarcode
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
