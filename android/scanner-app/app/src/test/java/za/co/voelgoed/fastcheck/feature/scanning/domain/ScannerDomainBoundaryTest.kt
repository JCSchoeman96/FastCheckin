package za.co.voelgoed.fastcheck.feature.scanning.domain

import com.google.common.truth.Truth.assertThat
import java.io.File
import org.junit.Test

class ScannerDomainBoundaryTest {
    @Test
    fun scannerDomainDoesNotDependOnFlushOrDiagnosticsTypes() {
        val domainRoot =
            sequenceOf(
                File("src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain"),
                File("app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain"),
                File("../app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain"),
                File("android/scanner-app/app/src/main/java/za/co/voelgoed/fastcheck/feature/scanning/domain")
            ).firstOrNull { it.exists() }
                ?: error("Could not locate scanner domain sources.")

        val sourceText =
            domainRoot.walkTopDown()
                .filter { file -> file.isFile && file.extension == "kt" }
                .joinToString(separator = "\n") { file -> file.readText() }

        assertThat(sourceText).doesNotContain("FlushReport")
        assertThat(sourceText).doesNotContain("FlushExecutionStatus")
        assertThat(sourceText).doesNotContain("DiagnosticsUiState")
        assertThat(sourceText).doesNotContain("QueueUiState")
        assertThat(sourceText).doesNotContain("QueueCreationResult")
        assertThat(sourceText).doesNotContain("FlushQueuedScansUseCase")
    }
}
