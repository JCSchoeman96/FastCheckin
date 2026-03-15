package za.co.voelgoed.fastcheck

import com.google.common.truth.Truth.assertThat
import java.io.File
import org.junit.Test

class RuntimeContractAuditTest {
    @Test
    fun runtimeCodeReferencesOnlyCurrentPhoenixMobileEndpoints() {
        val runtimeRoot = runtimeRoot()

        val sourceText =
            runtimeRoot.walkTopDown()
                .filter { file -> file.isFile && file.extension == "kt" }
                .joinToString(separator = "\n") { file -> file.readText() }

        assertThat(sourceText).contains("/api/v1/mobile/login")
        assertThat(sourceText).contains("/api/v1/mobile/attendees")
        assertThat(sourceText).contains("/api/v1/mobile/scans")
        assertThat(sourceText).doesNotContain("/api/v1/device_sessions")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins/flush")
        assertThat(sourceText).doesNotContain("OfflineEventPackage")
        assertThat(sourceText).doesNotContain("DeviceSession")
    }

    @Test
    fun runtimeCodeUsesScannerAndQueueUiPackagesWithoutFutureBackendRoutes() {
        val runtimeRoot = runtimeRoot()
        val sourceText =
            runtimeRoot.walkTopDown()
                .filter { file -> file.isFile && file.extension == "kt" }
                .joinToString(separator = "\n") { file -> file.readText() }

        assertThat(sourceText).contains("feature.queue.QueueViewModel")
        assertThat(sourceText).contains("feature.scanning.ui.ScanningViewModel")
        assertThat(sourceText).contains("feature.scanning.ui.ScanningUiState")
        assertThat(sourceText).doesNotContain("domain.model.FlushSummary")
        assertThat(sourceText).doesNotContain("class FlushSummary")
        assertThat(sourceText).doesNotContain("/api/v1/device_sessions")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins")
    }

    private fun runtimeRoot(): File =
        sequenceOf(
            File("src/main/java/za/co/voelgoed/fastcheck"),
            File("app/src/main/java/za/co/voelgoed/fastcheck"),
            File("../app/src/main/java/za/co/voelgoed/fastcheck"),
            File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck")
        ).firstOrNull { it.exists() }
            ?: error("Could not locate app/src/main runtime sources from ${File(".").absolutePath}.")
}
