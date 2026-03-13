package za.co.voelgoed.fastcheck.app.di

import androidx.camera.core.ImageAnalysis
import com.google.mlkit.vision.barcode.BarcodeScanner
import dagger.Binds
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.common.AppDispatchers
import za.co.voelgoed.fastcheck.feature.scanning.analysis.BarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.analysis.DecodedBarcodeHandler
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeFrameAnalyzer
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeScannerFactory
import za.co.voelgoed.fastcheck.feature.scanning.analysis.ScannerFormatConfig
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerCaptureConfig
import za.co.voelgoed.fastcheck.feature.scanning.domain.ScannerFeedbackConfig
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopController
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScannerLoopCoordinator

@Module
@InstallIn(SingletonComponent::class)
abstract class ScannerFeatureModule {
    @Binds
    abstract fun bindDecodedBarcodeHandler(
        coordinator: ScannerLoopCoordinator
    ): DecodedBarcodeHandler

    @Binds
    @Singleton
    abstract fun bindBarcodeScannerEngine(
        engine: MlKitBarcodeScannerEngine
    ): BarcodeScannerEngine

    @Binds
    abstract fun bindScannerLoopController(
        coordinator: ScannerLoopCoordinator
    ): ScannerLoopController

    @Binds
    abstract fun bindImageAnalysisAnalyzer(
        analyzer: MlKitBarcodeFrameAnalyzer
    ): ImageAnalysis.Analyzer

    companion object {
        @Provides
        @Singleton
        fun provideAppDispatchers(): AppDispatchers = AppDispatchers()

        @Provides
        @Singleton
        fun provideScannerFormatConfig(): ScannerFormatConfig = ScannerFormatConfig.fastCheckDefault

        @Provides
        @Singleton
        fun provideScannerCameraConfig(): ScannerCameraConfig = ScannerCameraConfig.default

        @Provides
        @Singleton
        fun provideScannerCaptureConfig(): ScannerCaptureConfig = ScannerCaptureConfig.default

        @Provides
        @Singleton
        fun provideScannerFeedbackConfig(): ScannerFeedbackConfig = ScannerFeedbackConfig.default

        @Provides
        @Singleton
        fun provideBarcodeScanner(
            factory: MlKitBarcodeScannerFactory
        ): BarcodeScanner = factory.create()
    }
}
