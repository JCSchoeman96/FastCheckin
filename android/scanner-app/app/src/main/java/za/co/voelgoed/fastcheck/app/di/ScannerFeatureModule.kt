package za.co.voelgoed.fastcheck.app.di

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
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeScannerEngine
import za.co.voelgoed.fastcheck.feature.scanning.analysis.MlKitBarcodeScannerFactory
import za.co.voelgoed.fastcheck.feature.scanning.analysis.ScannerFormatConfig
import za.co.voelgoed.fastcheck.feature.scanning.camera.ScannerCameraConfig
import za.co.voelgoed.fastcheck.feature.scanning.usecase.ScanCapturePipeline

@Module
@InstallIn(SingletonComponent::class)
abstract class ScannerFeatureModule {
    @Binds
    abstract fun bindDecodedBarcodeHandler(
        pipeline: ScanCapturePipeline
    ): DecodedBarcodeHandler

    @Binds
    @Singleton
    abstract fun bindBarcodeScannerEngine(
        engine: MlKitBarcodeScannerEngine
    ): BarcodeScannerEngine

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
        fun provideBarcodeScanner(
            factory: MlKitBarcodeScannerFactory
        ): BarcodeScanner = factory.create()
    }
}
