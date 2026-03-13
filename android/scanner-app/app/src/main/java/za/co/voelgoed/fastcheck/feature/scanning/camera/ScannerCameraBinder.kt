package za.co.voelgoed.fastcheck.feature.scanning.camera

import android.content.Context
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

data class ScannerCameraBinding(
    val config: ScannerCameraConfig,
    val hasImageAnalysis: Boolean
)

@Singleton
open class ScannerCameraBinder @Inject constructor(
    @param:ApplicationContext private val context: Context,
    private val scannerCameraConfig: ScannerCameraConfig,
    private val scannerFrameClosingAnalyzer: ScannerFrameClosingAnalyzer
) {
    open fun bindPreview(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        onBound: () -> Unit,
        onError: (Throwable) -> Unit
    ) {
        bind(
            lifecycleOwner = lifecycleOwner,
            previewView = previewView,
            analyzer = null,
            onBound = { onBound() },
            onError = onError
        )
    }

    open fun bindCameraPipeline(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        onBound: (ScannerCameraBinding) -> Unit,
        onError: (Throwable) -> Unit
    ) {
        bind(
            lifecycleOwner = lifecycleOwner,
            previewView = previewView,
            analyzer = scannerFrameClosingAnalyzer,
            onBound = onBound,
            onError = onError
        )
    }

    private fun bind(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        analyzer: ImageAnalysis.Analyzer?,
        onBound: (ScannerCameraBinding) -> Unit,
        onError: (Throwable) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(context)
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener(
            {
                try {
                    val cameraProvider = cameraProviderFuture.get()
                    val preview =
                        Preview.Builder()
                            .applyCameraConfig(scannerCameraConfig)
                            .build()
                            .also { useCase ->
                                useCase.surfaceProvider = previewView.surfaceProvider
                            }
                    val imageAnalysis =
                        analyzer?.let { imageAnalyzer ->
                            ImageAnalysis.Builder()
                                .applyCameraConfig(scannerCameraConfig)
                                .setBackpressureStrategy(scannerCameraConfig.backpressureStrategy)
                                .build()
                                .also { useCase ->
                                    useCase.setAnalyzer(executor, imageAnalyzer)
                                }
                        }

                    cameraProvider.unbindAll()
                    if (imageAnalysis != null) {
                        cameraProvider.bindToLifecycle(
                            lifecycleOwner,
                            scannerCameraConfig.cameraSelector(),
                            preview,
                            imageAnalysis
                        )
                    } else {
                        cameraProvider.bindToLifecycle(
                            lifecycleOwner,
                            scannerCameraConfig.cameraSelector(),
                            preview
                        )
                    }
                    onBound(
                        ScannerCameraBinding(
                            config = scannerCameraConfig,
                            hasImageAnalysis = imageAnalysis != null
                        )
                    )
                } catch (throwable: Throwable) {
                    onError(throwable)
                }
            },
            executor
        )
    }

    @Suppress("DEPRECATION")
    private fun Preview.Builder.applyCameraConfig(
        config: ScannerCameraConfig
    ): Preview.Builder =
        apply {
            if (config.targetResolution != null) {
                setTargetResolution(config.targetResolution)
            } else {
                setTargetAspectRatio(config.aspectRatio)
            }
        }

    @Suppress("DEPRECATION")
    private fun ImageAnalysis.Builder.applyCameraConfig(
        config: ScannerCameraConfig
    ): ImageAnalysis.Builder =
        apply {
            if (config.targetResolution != null) {
                setTargetResolution(config.targetResolution)
            } else {
                setTargetAspectRatio(config.aspectRatio)
            }
        }
}
