package za.co.voelgoed.fastcheck

import com.google.common.truth.Truth.assertThat
import java.io.File
import org.junit.Test

class RuntimeContractAuditTest {
    @Test
    fun runtimeCodeReferencesOnlyCurrentPhoenixMobileEndpoints() {
        val sourceText = runtimeSourceText()

        assertThat(sourceText).contains("/api/v1/mobile/login")
        assertThat(sourceText).contains("/api/v1/mobile/attendees")
        assertThat(sourceText).contains("/api/v1/mobile/scans")
        assertThat(sourceText).doesNotContain("/api/v1/device_sessions")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins/flush")
        assertThat(sourceText).doesNotContain("/api/v1/events/")
        assertThat(sourceText).doesNotContain("OfflineEventPackage")
        assertThat(sourceText).doesNotContain("DeviceSession")
    }

    @Test
    fun runtimeCodeUsesScannerAndQueueUiPackagesWithoutFutureBackendRoutes() {
        val sourceText = runtimeSourceText()

        assertThat(sourceText).contains("feature.queue.QueueViewModel")
        assertThat(sourceText).contains("feature.scanning.ui.ScanningViewModel")
        assertThat(sourceText).contains("ScanningUiState")
        assertThat(sourceText).doesNotContain("domain.model.FlushSummary")
        assertThat(sourceText).doesNotContain("class FlushSummary")
        assertThat(sourceText).doesNotContain("/api/v1/device_sessions")
        assertThat(sourceText).doesNotContain("/api/v1/check_ins")
    }

    @Test
    fun scannerFeatureDoesNotDependDirectlyOnInfrastructureTypes() {
        val scannerRoot = File(runtimeRoot(), "feature/scanning")
        val sourceText =
            scannerRoot.walkTopDown()
                .filter { file -> file.isFile && file.extension == "kt" }
                .joinToString(separator = "\n") { file -> file.readText() }

        assertThat(sourceText).doesNotContain("ScannerDao")
        assertThat(sourceText).doesNotContain("FastCheckDatabase")
        assertThat(sourceText).doesNotContain("CurrentPhoenixMobileScanRepository")
        assertThat(sourceText).doesNotContain("FlushQueueWorker")
        assertThat(sourceText).doesNotContain("PhoenixMobileApi")
        assertThat(sourceText).doesNotContain("PhoenixMobileRemoteDataSource")
    }

    @Test
    fun activeUiSourcesRemainInOnlyEvenThoughDirectionTypeStillExists() {
        val sourceText =
            listOf(
                runtimeFile("feature/queue/QueueViewModel.kt"),
                runtimeFile("feature/queue/QueueUiState.kt"),
                runtimeFile("feature/scanning/ui/ScanningViewModel.kt"),
                runtimeFile("app/MainActivity.kt")
            ).joinToString(separator = "\n") { file -> file.readText() }

        assertThat(sourceText).contains("ScanDirection.IN")
        assertThat(sourceText).contains("directionLabel: String = \"IN\"")
        assertThat(sourceText).doesNotContain("ScanDirection.OUT")
    }

    @Test
    fun currentRuntimeCodeDoesNotParseServerMessagesIntoBusinessTruth() {
        val classifierSource = runtimeFile("data/repository/FlushResultClassifier.kt").readText()
        val repositorySource =
            runtimeFile("data/repository/CurrentPhoenixMobileScanRepository.kt").readText()
        val diagnosticsSource = runtimeFile("feature/diagnostics/DiagnosticsUiStateFactory.kt").readText()

        assertThat(classifierSource).contains("uploadedResult.status.lowercase()")
        assertThat(classifierSource).doesNotContain("uploadedResult.message.lowercase()")
        assertThat(classifierSource).doesNotContain("uploadedResult.message.contains(")
        assertThat(classifierSource).doesNotContain("when (uploadedResult.message")
        assertThat(classifierSource).doesNotContain("if (uploadedResult.message")

        assertThat(repositorySource).doesNotContain(".message.contains(")
        assertThat(repositorySource).doesNotContain(".message.lowercase(")
        assertThat(diagnosticsSource).doesNotContain(".message.contains(")
        assertThat(diagnosticsSource).doesNotContain(".message.lowercase(")
    }

    @Test
    fun lockdownDocsStateCanonicalRuntimeTruth() {
        val rawPayloadPhrase =
            "Raw scanned payload must currently be preserved exactly; no client normalization policy is promoted."
        val directionPhrase =
            "Android runtime remains effectively IN-only; OUT is not a promoted successful business flow."
        val modePhrase =
            "redis_authoritative is the target/proven path in tests and perf; legacy and shadow are fallback/migration modes; deployed production truth cannot be proven from repo code alone."

        val lockdownDoc = repoFile("docs/runtime_truth_lockdown.md", "android/scanner-app/docs/runtime_truth_lockdown.md").readText()
        val mobileTruthDoc = repoFile("docs/mobile_runtime_truth.md", "../../docs/mobile_runtime_truth.md").readText()
        val currentApiDoc =
            repoFile("CURRENT_PHOENIX_MOBILE_API.md", "android/scanner-app/CURRENT_PHOENIX_MOBILE_API.md").readText()
        val backendGapsDoc =
            repoFile("docs/backend_gaps.md", "android/scanner-app/docs/backend_gaps.md").readText()
        val queueDoc =
            repoFile("docs/queue_and_flush.md", "android/scanner-app/docs/queue_and_flush.md").readText()

        listOf(lockdownDoc, mobileTruthDoc, currentApiDoc, backendGapsDoc, queueDoc).forEach { text ->
            assertThat(text).contains(rawPayloadPhrase)
            assertThat(text).contains(directionPhrase)
        }

        assertThat(lockdownDoc).contains(modePhrase)
        assertThat(mobileTruthDoc).contains(modePhrase)
    }

    @Test
    fun lockdownDocsDoNotReintroduceKnownDriftPhrases() {
        val auditedDocs =
            listOf(
                repoFile("docs/runtime_truth_lockdown.md", "android/scanner-app/docs/runtime_truth_lockdown.md"),
                repoFile("docs/mobile_runtime_truth.md", "../../docs/mobile_runtime_truth.md"),
                repoFile("CURRENT_PHOENIX_MOBILE_API.md", "android/scanner-app/CURRENT_PHOENIX_MOBILE_API.md"),
                repoFile("docs/backend_gaps.md", "android/scanner-app/docs/backend_gaps.md"),
                repoFile("docs/queue_and_flush.md", "android/scanner-app/docs/queue_and_flush.md")
            ).joinToString(separator = "\n") { file -> file.readText() }

        assertThat(auditedDocs).doesNotContain("transport-safe trimming")
        assertThat(auditedDocs).doesNotContain("status/message combinations")
        assertThat(auditedDocs).doesNotContain("legacy is the promoted runtime")
        assertThat(auditedDocs).doesNotContain("shadow is the promoted runtime")
    }

    private fun runtimeSourceText(): String =
        runtimeRoot().walkTopDown()
            .filter { file -> file.isFile && file.extension == "kt" }
            .joinToString(separator = "\n") { file -> file.readText() }

    private fun runtimeFile(relativePath: String): File {
        val file = File(runtimeRoot(), relativePath)
        check(file.exists()) { "Could not locate runtime file: $relativePath" }
        return file
    }

    private fun repoFile(vararg candidates: String): File {
        val searchRoots = sequenceOf(File("."), File(".."), File("../.."), File("../../.."))

        return candidates.asSequence()
            .flatMap { candidate ->
                searchRoots.map { root -> File(root, candidate).normalize() }
            }
            .firstOrNull { it.exists() }
            ?: error("Could not locate any of: ${candidates.joinToString()}")
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
