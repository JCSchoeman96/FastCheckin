package za.co.voelgoed.fastcheck.feature.scanning.camera

import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerCameraBinderTest {
    @Test
    fun defaultConfigUsesBackCameraFourByThreeAndKeepOnlyLatest() {
        val config = ScannerCameraConfig.default

        assertThat(config.lensFacing).isEqualTo(CameraSelector.LENS_FACING_BACK)
        assertThat(config.aspectRatio).isEqualTo(AspectRatio.RATIO_4_3)
        assertThat(config.targetResolution).isNull()
        assertThat(config.backpressureStrategy)
            .isEqualTo(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
    }

    @Test
    fun cameraSelectorIsDerivedFromConfiguredLensFacing() {
        val config = ScannerCameraConfig(lensFacing = CameraSelector.LENS_FACING_FRONT)

        assertThat(config.cameraSelector().lensFacing).isEqualTo(CameraSelector.LENS_FACING_FRONT)
    }

    @Test
    fun previewOnlyBindingDoesNotRequireAnalyzerParameter() {
        val bindPreview =
            ScannerCameraBinder::class.java.methods.single { method ->
                method.name == "bindPreview"
            }

        assertThat(bindPreview.parameterTypes.toList()).doesNotContain(ImageAnalysis.Analyzer::class.java)
    }

    @Test
    fun primaryPipelineBindingDoesNotRequireAnalyzerParameter() {
        val bindCameraPipeline =
            ScannerCameraBinder::class.java.methods.single { method ->
                method.name == "bindCameraPipeline"
            }

        assertThat(bindCameraPipeline.parameterTypes.toList())
            .doesNotContain(ImageAnalysis.Analyzer::class.java)
    }

    @Test
    fun binderConstructorStaysInsideScannerCameraConcerns() {
        val constructor = ScannerCameraBinder::class.java.declaredConstructors.single()
        val parameterNames = constructor.parameterTypes.map(Class<*>::getName)

        assertThat(parameterNames)
            .containsExactly(
                "android.content.Context",
                ScannerCameraConfig::class.java.name,
                ScannerFrameClosingAnalyzer::class.java.name
            )
    }
}
