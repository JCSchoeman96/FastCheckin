package za.co.voelgoed.fastcheck

import com.google.common.truth.Truth.assertThat
import java.io.File
import org.junit.Test

class RuntimeContractAuditTest {
    @Test
    fun runtimeCodeReferencesOnlyCurrentPhoenixMobileEndpoints() {
        val sourceText = phoenixMobileApiSource().readText()

        assertThat(sourceText).contains("/api/v1/mobile/login")
        assertThat(sourceText).contains("/api/v1/mobile/attendees")
        assertThat(sourceText).contains("/api/v1/mobile/scans")
        assertThat(sourceText).doesNotContain("/api/v1/device_sessions")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins/flush")
    }

    @Test
    fun scanResultClassificationDoesNotBranchOnMessage() {
        val classifierSource = flushResultClassifierSource().readText()
        val repositorySource = mobileScanRepositorySource().readText()

        assertThat(classifierSource).contains("when (uploadedResult.status.lowercase())")
        assertThat(classifierSource).doesNotContain("uploadedResult.message.lowercase()")
        assertThat(classifierSource).doesNotContain("uploadedResult.message.contains(")
        assertThat(repositorySource).contains("it.outcome != FlushItemOutcome.RETRYABLE_FAILURE")
        assertThat(repositorySource).doesNotContain(".message.lowercase()")
        assertThat(repositorySource).doesNotContain(".message.contains(")
    }

    @Test
    fun flushOutcomeModelStaysBroadAndDoesNotMirrorBackendTaxonomy() {
        val sourceText = flushReportSource().readText()

        assertThat(sourceText).contains("enum class FlushItemOutcome")
        assertThat(sourceText).contains("SUCCESS")
        assertThat(sourceText).contains("DUPLICATE")
        assertThat(sourceText).contains("TERMINAL_ERROR")
        assertThat(sourceText).contains("RETRYABLE_FAILURE")
        assertThat(sourceText).contains("AUTH_EXPIRED")
        assertThat(sourceText).doesNotContain("BUSINESS_DUPLICATE")
        assertThat(sourceText).doesNotContain("PAYMENT_INVALID")
        assertThat(sourceText).doesNotContain("REPLAY_DUPLICATE")
    }

    private fun phoenixMobileApiSource(): File =
        sequenceOf(
            File("src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt"),
            File("app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt"),
            File("../app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt"),
            File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/core/network/PhoenixMobileApi.kt")
        ).firstOrNull { it.exists() }
            ?: error("Could not locate PhoenixMobileApi.kt from ${File(".").absolutePath}.")

    private fun flushResultClassifierSource(): File =
        sequenceOf(
            File("src/main/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifier.kt"),
            File("app/src/main/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifier.kt"),
            File("../app/src/main/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifier.kt"),
            File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/FlushResultClassifier.kt")
        ).firstOrNull { it.exists() }
            ?: error("Could not locate FlushResultClassifier.kt from ${File(".").absolutePath}.")

    private fun mobileScanRepositorySource(): File =
        sequenceOf(
            File("src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt"),
            File("app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt"),
            File("../app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt"),
            File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/data/repository/CurrentPhoenixMobileScanRepository.kt")
        ).firstOrNull { it.exists() }
            ?: error("Could not locate CurrentPhoenixMobileScanRepository.kt from ${File(".").absolutePath}.")

    private fun flushReportSource(): File =
        sequenceOf(
            File("src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt"),
            File("app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt"),
            File("../app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt"),
            File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/domain/model/FlushReport.kt")
        ).firstOrNull { it.exists() }
            ?: error("Could not locate FlushReport.kt from ${File(".").absolutePath}.")
}
