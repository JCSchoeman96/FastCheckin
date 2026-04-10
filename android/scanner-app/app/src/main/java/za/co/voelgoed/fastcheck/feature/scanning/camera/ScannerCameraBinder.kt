package za.co.voelgoed.fastcheck.feature.scanning.camera

import android.content.Context
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.atomic.AtomicLong
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class ScannerCameraBinder @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val generationGuard = CameraBindGenerationGuard()

    fun bind(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        analyzer: ImageAnalysis.Analyzer,
        onBound: () -> Unit,
        onError: (Throwable) -> Unit
    ) {
        val bindGeneration = generationGuard.newBindGeneration()
        val executor = ContextCompat.getMainExecutor(context)
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        cameraProviderFuture.addListener(
            {
                if (!generationGuard.isActive(bindGeneration)) {
                    return@addListener
                }

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

                    if (!generationGuard.isActive(bindGeneration)) {
                        return@addListener
                    }

                    cameraProvider.unbindAll()
                    if (!generationGuard.isActive(bindGeneration)) {
                        return@addListener
                    }
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        ScannerCameraConfig.cameraSelector,
                        preview,
                        imageAnalysis
                    )
                    if (generationGuard.isActive(bindGeneration)) {
                        onBound()
                    } else {
                        // A newer request superseded this bind; clean up best-effort.
                        runCatching { cameraProvider.unbindAll() }
                    }
                } catch (throwable: Throwable) {
                    if (generationGuard.isActive(bindGeneration)) {
                        onError(throwable)
                    }
                }
            },
            executor
        )
    }

    fun unbindAll() {
        generationGuard.invalidateActiveGeneration()
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        if (cameraProviderFuture.isDone) {
            try {
                cameraProviderFuture.get().unbindAll()
            } catch (_throwable: Throwable) {
                // Best-effort cleanup only.
            }
        }
    }
}

internal class CameraBindGenerationGuard {
    private val activeGeneration = AtomicLong(0)

    fun newBindGeneration(): Long = activeGeneration.incrementAndGet()

    fun invalidateActiveGeneration() {
        activeGeneration.incrementAndGet()
    }

    fun isActive(generation: Long): Boolean = activeGeneration.get() == generation
}
