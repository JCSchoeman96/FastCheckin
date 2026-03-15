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

@Singleton
class ScannerCameraBinder @Inject constructor(
    @ApplicationContext private val context: Context
) {
    fun bind(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        analyzer: ImageAnalysis.Analyzer,
        onBound: () -> Unit,
        onError: (Throwable) -> Unit
    ) {
        val executor = ContextCompat.getMainExecutor(context)
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener(
            {
                try {
                    val cameraProvider = cameraProviderFuture.get()
                    val preview =
                        Preview.Builder().build().also { useCase ->
                            useCase.surfaceProvider = previewView.surfaceProvider
                        }
                    val imageAnalysis =
                        ImageAnalysis.Builder()
                            .setBackpressureStrategy(ScannerCameraConfig.backpressureStrategy)
                            .build()
                            .also { useCase ->
                                useCase.setAnalyzer(executor, analyzer)
                            }

                    cameraProvider.unbindAll()
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        ScannerCameraConfig.cameraSelector,
                        preview,
                        imageAnalysis
                    )
                    onBound()
                } catch (throwable: Throwable) {
                    onError(throwable)
                }
            },
            executor
        )
    }
}
