package za.co.voelgoed.fastcheck.core.network

import za.co.voelgoed.fastcheck.BuildConfig

data class ApiEnvironmentConfig(
    val target: ApiTarget,
    val baseUrl: String
)

enum class ApiTarget(val wireName: String) {
    DEV("dev"),
    EMULATOR("emulator"),
    DEVICE("device"),
    RELEASE("release");

    companion object {
        fun fromBuildConfig(value: String): ApiTarget =
            entries.firstOrNull { it.wireName.equals(value.trim(), ignoreCase = true) } ?: RELEASE
    }
}

class ApiEnvironmentConfigResolver {
    fun resolve(
        apiTarget: String = BuildConfig.API_TARGET,
        releaseBaseUrl: String = BuildConfig.API_BASE_URL_RELEASE,
        emulatorBaseUrl: String = BuildConfig.API_BASE_URL_EMULATOR,
        devBaseUrl: String = BuildConfig.API_BASE_URL_DEV,
        deviceBaseUrl: String = BuildConfig.API_BASE_URL_DEVICE
    ): ApiEnvironmentConfig {
        val target = ApiTarget.fromBuildConfig(apiTarget)
        val baseUrl =
            when (target) {
                ApiTarget.DEV -> devBaseUrl
                ApiTarget.EMULATOR -> emulatorBaseUrl
                ApiTarget.DEVICE -> deviceBaseUrl
                ApiTarget.RELEASE -> releaseBaseUrl
            }.normalizedBaseUrl()

        return ApiEnvironmentConfig(target = target, baseUrl = baseUrl)
    }

    private fun String.normalizedBaseUrl(): String =
        trim().let { value ->
            if (value.endsWith("/")) value else "$value/"
        }
}
