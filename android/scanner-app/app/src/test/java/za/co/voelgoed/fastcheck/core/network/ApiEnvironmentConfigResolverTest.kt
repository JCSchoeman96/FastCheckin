package za.co.voelgoed.fastcheck.core.network

import com.google.common.truth.Truth.assertThat
import org.junit.Test

class ApiEnvironmentConfigResolverTest {
    private val resolver = ApiEnvironmentConfigResolver()

    @Test
    fun normalizesTrailingSlashForSelectedTarget() {
        val resolved =
            resolver.resolve(
                apiTarget = "dev",
                releaseBaseUrl = "https://release.example.com",
                emulatorBaseUrl = "http://10.0.2.2:4000",
                devBaseUrl = "https://dev.example.com",
                deviceBaseUrl = "https://device.example.com"
            )

        assertThat(resolved.target).isEqualTo(ApiTarget.DEV)
        assertThat(resolved.baseUrl).isEqualTo("https://dev.example.com/")
    }

    @Test
    fun fallsBackToReleaseForUnknownTarget() {
        val resolved =
            resolver.resolve(
                apiTarget = "mystery",
                releaseBaseUrl = "https://release.example.com",
                emulatorBaseUrl = "http://10.0.2.2:4000",
                devBaseUrl = "https://dev.example.com",
                deviceBaseUrl = "https://device.example.com"
            )

        assertThat(resolved.target).isEqualTo(ApiTarget.RELEASE)
        assertThat(resolved.baseUrl).isEqualTo("https://release.example.com/")
    }
}
