package za.co.voelgoed.fastcheck.core.network

import java.net.URI
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
            entries.firstOrNull { it.wireName.equals(value.trim(), ignoreCase = true) }
                ?: throw IllegalArgumentException("Unknown FASTCHECK_API_TARGET '$value'.")
    }
}

class ApiEnvironmentConfigResolver {
    fun resolve(
        apiTarget: String = BuildConfig.API_TARGET,
        selectedBaseUrl: String = BuildConfig.API_BASE_URL
    ): ApiEnvironmentConfig {
        val target = ApiTarget.fromBuildConfig(apiTarget)
        val baseUrl = validateAndNormalizeBaseUrl(target, selectedBaseUrl)

        return ApiEnvironmentConfig(target = target, baseUrl = baseUrl)
    }

    private fun validateAndNormalizeBaseUrl(target: ApiTarget, rawValue: String): String {
        val trimmed = rawValue.trim()
        require(trimmed.isNotBlank()) { "API base URL must not be blank for target ${target.wireName}." }

        val normalized = if (trimmed.endsWith("/")) trimmed else "$trimmed/"
        val uri =
            try {
                URI(normalized)
            } catch (error: Exception) {
                throw IllegalArgumentException("API base URL must be a valid absolute URL.", error)
            }

        require(uri.isAbsolute && !uri.host.isNullOrBlank()) {
            "API base URL must be a valid absolute URL."
        }

        val scheme = uri.scheme.lowercase()
        val allowedSchemes =
            when (target) {
                ApiTarget.DEV -> setOf("http", "https")
                ApiTarget.EMULATOR -> setOf("http")
                ApiTarget.DEVICE,
                ApiTarget.RELEASE -> setOf("https")
            }

        require(scheme in allowedSchemes) {
            "Target ${target.wireName} requires one of ${allowedSchemes.joinToString()}."
        }

        if (target == ApiTarget.EMULATOR) {
            require(normalized == EMULATOR_BASE_URL) {
                "Emulator target must use $EMULATOR_BASE_URL."
            }
        }

        return normalized
    }

    companion object {
        const val EMULATOR_BASE_URL = "http://10.0.2.2:4000/"
        const val RELEASE_BASE_URL = "https://scan.voelgoed.co.za/"
    }
}
