package za.co.voelgoed.fastcheck.core.network

import com.google.common.truth.Truth.assertThat
import com.google.common.truth.Truth.assertWithMessage
import org.junit.Test

class ApiEnvironmentConfigResolverTest {
    private val resolver = ApiEnvironmentConfigResolver()

    @Test
    fun emulatorResolvesExpectedBaseUrl() {
        val resolved =
            resolver.resolve(
                apiTarget = "emulator",
                selectedBaseUrl = "http://10.0.2.2:4000/"
            )

        assertThat(resolved.target).isEqualTo(ApiTarget.EMULATOR)
        assertThat(resolved.baseUrl).isEqualTo(ApiEnvironmentConfigResolver.EMULATOR_BASE_URL)
    }

    @Test
    fun devRequiresExplicitPropertyAndFailsLoudlyIfMissing() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "dev",
                    selectedBaseUrl = ""
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("must not be blank")
    }

    @Test
    fun deviceRequiresExplicitPropertyAndFailsLoudlyIfMissing() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "device",
                    selectedBaseUrl = " "
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("must not be blank")
    }

    @Test
    fun releaseResolvesOnlyReleaseSafeUrlConfig() {
        val resolved =
            resolver.resolve(
                apiTarget = "release",
                selectedBaseUrl = ApiEnvironmentConfigResolver.RELEASE_BASE_URL
            )

        assertThat(resolved.target).isEqualTo(ApiTarget.RELEASE)
        assertThat(resolved.baseUrl).isEqualTo(ApiEnvironmentConfigResolver.RELEASE_BASE_URL)
    }

    @Test
    fun unknownTargetFailsLoudly() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "mystery",
                    selectedBaseUrl = ApiEnvironmentConfigResolver.RELEASE_BASE_URL
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("Unknown FASTCHECK_API_TARGET")
    }

    @Test
    fun blankUrlPropertyFailsLoudly() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "release",
                    selectedBaseUrl = ""
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("must not be blank")
    }

    @Test
    fun invalidAbsoluteUrlFailsLoudly() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "dev",
                    selectedBaseUrl = "not-a-url"
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("valid absolute URL")
    }

    @Test
    fun trailingSlashNormalizationIsDeterministic() {
        val resolved =
            resolver.resolve(
                apiTarget = "dev",
                selectedBaseUrl = "https://dev.example.com"
            )

        assertThat(resolved.baseUrl).isEqualTo("https://dev.example.com/")
    }

    @Test
    fun releaseDoesNotSilentlyFallBackToEmulatorOrDevBehavior() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "release",
                    selectedBaseUrl = "http://10.0.2.2:4000/"
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("requires one of https")
    }

    @Test
    fun deviceRequiresHttps() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "device",
                    selectedBaseUrl = "http://device.example.com/"
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertThat(error).hasMessageThat().contains("requires one of https")
    }

    @Test
    fun emulatorRejectsNonCanonicalUrl() {
        val error =
            runCatching {
                resolver.resolve(
                    apiTarget = "emulator",
                    selectedBaseUrl = "http://localhost:4000/"
                )
            }.exceptionOrNull()

        assertThat(error).isInstanceOf(IllegalArgumentException::class.java)
        assertWithMessage("emulator must stay fixed to 10.0.2.2").that(error!!.message)
            .contains(ApiEnvironmentConfigResolver.EMULATOR_BASE_URL)
    }
}
