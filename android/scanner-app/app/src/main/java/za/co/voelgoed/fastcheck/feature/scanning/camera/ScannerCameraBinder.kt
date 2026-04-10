package za.co.voelgoed.fastcheck.feature.scanning.camera

import android.content.Context
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicLong
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton
import za.co.voelgoed.fastcheck.core.common.ScannerRuntimeLogger

@Singleton
class ScannerCameraBinder @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private val generationGuard = CameraBindGenerationGuard()
    private val mainExecutor: Executor = ContextCompat.getMainExecutor(context)
    private val analysisExecutorOwner = AnalysisExecutorOwner()

    fun bind(
        lifecycleOwner: LifecycleOwner,
        previewView: PreviewView,
        analyzer: ImageAnalysis.Analyzer,
        onBound: () -> Unit,
        onError: (Throwable) -> Unit
    ) {
        val bindGeneration = generationGuard.newBindGeneration()
        val analysisExecutor = analysisExecutorOwner.ensureExecutor()
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        ScannerRuntimeLogger.i(
            LOG_TAG,
            "bind_requested generation=$bindGeneration previewAttached=${previewView.isAttachedToWindow} " +
                "previewVisible=${previewView.visibility == android.view.View.VISIBLE}"
        )

        cameraProviderFuture.addListener(
            {
                if (!generationGuard.isActive(bindGeneration)) {
                    ScannerRuntimeLogger.i(LOG_TAG, "bind_skipped_stale generation=$bindGeneration")
                    return@addListener
                }

                try {
                    val cameraProvider = cameraProviderFuture.get()
                    ScannerRuntimeLogger.d(LOG_TAG, "camera_provider_ready generation=$bindGeneration")
                    val preview =
                        Preview.Builder().build().also { useCase ->
                            useCase.surfaceProvider = previewView.surfaceProvider
                        }
                    val imageAnalysis =
                        ImageAnalysis.Builder()
                            .setBackpressureStrategy(ScannerCameraConfig.backpressureStrategy)
                            .build()
                            .also { useCase ->
                                useCase.setAnalyzer(analysisExecutor, analyzer)
                                ScannerRuntimeLogger.i(
                                    LOG_TAG,
                                    "analyzer_attached generation=$bindGeneration executor=analysis_single_thread"
                                )
                            }

                    if (!generationGuard.isActive(bindGeneration)) {
                        ScannerRuntimeLogger.i(
                            LOG_TAG,
                            "bind_skipped_stale_after_analyzer generation=$bindGeneration"
                        )
                        return@addListener
                    }

                    cameraProvider.unbindAll()
                    if (!generationGuard.isActive(bindGeneration)) {
                        ScannerRuntimeLogger.i(
                            LOG_TAG,
                            "bind_skipped_stale_after_unbind generation=$bindGeneration"
                        )
                        return@addListener
                    }
                    cameraProvider.bindToLifecycle(
                        lifecycleOwner,
                        ScannerCameraConfig.cameraSelector,
                        preview,
                        imageAnalysis
                    )
                    if (generationGuard.isActive(bindGeneration)) {
                        ScannerRuntimeLogger.i(LOG_TAG, "bind_success generation=$bindGeneration")
                        onBound()
                    } else {
                        // A newer request superseded this bind; clean up best-effort.
                        runCatching { cameraProvider.unbindAll() }
                        ScannerRuntimeLogger.i(
                            LOG_TAG,
                            "bind_superseded_cleanup generation=$bindGeneration"
                        )
                    }
                } catch (throwable: Throwable) {
                    if (generationGuard.isActive(bindGeneration)) {
                        ScannerRuntimeLogger.e(
                            LOG_TAG,
                            "bind_error generation=$bindGeneration message=${throwable.message}",
                            throwable
                        )
                        onError(throwable)
                    }
                }
            },
            mainExecutor
        )
    }

    fun unbindAll() {
        ScannerRuntimeLogger.i(LOG_TAG, "unbind_requested")
        generationGuard.invalidateActiveGeneration()
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)

        if (cameraProviderFuture.isDone) {
            try {
                cameraProviderFuture.get().unbindAll()
                ScannerRuntimeLogger.i(LOG_TAG, "unbind_success")
            } catch (_throwable: Throwable) {
                // Best-effort cleanup only.
                ScannerRuntimeLogger.w(LOG_TAG, "unbind_failed_best_effort")
            }
        }
        analysisExecutorOwner.releaseExecutor()
    }

    private companion object {
        private const val LOG_TAG: String = "ScannerCameraBinder"
    }
}

internal class AnalysisExecutorOwner {
    private val lock = Any()
    private var analysisExecutor: ExecutorService? = null

    fun ensureExecutor(): Executor {
        synchronized(lock) {
            val existing = analysisExecutor
            if (existing != null && !existing.isShutdown) {
                return existing
            }
            val created =
                Executors.newSingleThreadExecutor(
                    ThreadFactory { runnable ->
                        Thread(runnable, "fc-scanner-analysis").apply {
                            isDaemon = true
                        }
                    }
                )
            analysisExecutor = created
            ScannerRuntimeLogger.i("ScannerCameraBinder", "analysis_executor_created")
            return created
        }
    }

    fun releaseExecutor() {
        synchronized(lock) {
            val executor = analysisExecutor ?: return
            analysisExecutor = null
            executor.shutdownNow()
            ScannerRuntimeLogger.i("ScannerCameraBinder", "analysis_executor_released")
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
