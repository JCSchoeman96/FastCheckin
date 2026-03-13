package za.co.voelgoed.fastcheck.feature.scanning.camera

import androidx.camera.core.ImageAnalysis
import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ScannerCameraBinderTest {
    @Test
    fun previewOnlyBindingDoesNotRequireAnalyzerParameter() {
        val bindPreview =
            ScannerCameraBinder::class.java.methods.single { method ->
                method.name == "bindPreview"
            }

        assertThat(bindPreview.parameterTypes.toList()).doesNotContain(ImageAnalysis.Analyzer::class.java)
    }
}
