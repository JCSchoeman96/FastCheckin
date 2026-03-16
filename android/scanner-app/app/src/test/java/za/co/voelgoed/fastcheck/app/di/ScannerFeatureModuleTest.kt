package za.co.voelgoed.fastcheck.app.di

import androidx.camera.core.ImageAnalysis
import com.google.common.truth.Truth.assertThat
import java.time.Clock
import org.junit.Test
import za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeFrameAnalyzer
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.analysis.ScannerFormatConfig
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopController
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopCoordinator

class ScannerFeatureModuleTest {
    @Test
    fun providerDefaultsExposeScannerConfigsWithoutSecondClock() {
        val companionClass = ScannerFeatureModule.Companion::class.java
        val providerMethods = companionClass.declaredMethods.associateBy { it.name }

        assertThat(
            providerMethods.getValue("provideScannerCaptureConfig")
                .invoke(ScannerFeatureModule.Companion)
        ).isEqualTo(ScannerCaptureConfig.default)
        assertThat(
            providerMethods.getValue("provideScannerFeedbackConfig")
                .invoke(ScannerFeatureModule.Companion)
        ).isEqualTo(ScannerFeedbackConfig.default)
        assertThat(
            providerMethods.getValue("provideScannerCameraConfig")
                .invoke(ScannerFeatureModule.Companion)
        ).isEqualTo(ScannerCameraConfig.default)
        assertThat(
            providerMethods.getValue("provideScannerFormatConfig")
                .invoke(ScannerFeatureModule.Companion)
        ).isEqualTo(ScannerFormatConfig.fastCheckDefault)
        assertThat(providerMethods.values.map { it.returnType }).doesNotContain(Clock::class.java)
    }

    @Test
    fun moduleDeclaresScannerBindingsIncludingRealAnalyzer() {
        val methods = ScannerFeatureModule::class.java.declaredMethods.associateBy { it.name }

        assertThat(methods.getValue("bindDecodedBarcodeHandler").returnType)
            .isEqualTo(DecodedBarcodeHandler::class.java)
        assertThat(methods.getValue("bindDecodedBarcodeHandler").parameterTypes.single())
            .isEqualTo(ScannerLoopCoordinator::class.java)

        assertThat(methods.getValue("bindBarcodeScannerEngine").returnType)
            .isEqualTo(BarcodeScannerEngine::class.java)
        assertThat(methods.getValue("bindBarcodeScannerEngine").parameterTypes.single())
            .isEqualTo(MlKitBarcodeScannerEngine::class.java)

        assertThat(methods.getValue("bindScannerLoopController").returnType)
            .isEqualTo(ScannerLoopController::class.java)
        assertThat(methods.getValue("bindScannerLoopController").parameterTypes.single())
            .isEqualTo(ScannerLoopCoordinator::class.java)

        assertThat(methods.getValue("bindImageAnalysisAnalyzer").returnType)
            .isEqualTo(ImageAnalysis.Analyzer::class.java)
        assertThat(methods.getValue("bindImageAnalysisAnalyzer").parameterTypes.single())
            .isEqualTo(MlKitBarcodeFrameAnalyzer::class.java)
    }
}
