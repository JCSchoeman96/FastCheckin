import com.android.build.api.dsl.ApplicationExtension
import java.net.URI
import org.gradle.kotlin.dsl.configure
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

val fastcheckApiTarget =
    (findProperty("FASTCHECK_API_TARGET") as String?)
        ?.trim()
        ?.lowercase()
        ?.takeIf { it.isNotBlank() }
        ?: "release"

val fastcheckScannerSource =
    (findProperty("FASTCHECK_SCANNER_SOURCE") as String?)
        ?.trim()
        ?.lowercase()
        ?.takeIf { it.isNotBlank() }
        ?: "camera"

val allowedApiTargets = setOf("dev", "emulator", "device", "release")
require(fastcheckApiTarget in allowedApiTargets) {
    "FASTCHECK_API_TARGET must be one of ${allowedApiTargets.joinToString()}, got '$fastcheckApiTarget'."
}

val allowedScannerSources = setOf("camera", "datawedge")
require(fastcheckScannerSource in allowedScannerSources) {
    "FASTCHECK_SCANNER_SOURCE must be one of ${allowedScannerSources.joinToString()}, got '$fastcheckScannerSource'."
}

val fixedReleaseApiBaseUrl = "https://scan.voelgoed.co.za/"
val fixedEmulatorApiBaseUrl = "http://10.0.2.2:4000/"

fun normalizeAndValidateBaseUrl(
    propertyName: String,
    rawValue: String,
    allowedSchemes: Set<String>
): String {
    val trimmed = rawValue.trim()
    require(trimmed.isNotBlank()) { "$propertyName must not be blank." }

    val normalized = if (trimmed.endsWith("/")) trimmed else "$trimmed/"
    val uri =
        try {
            URI(normalized)
        } catch (error: Exception) {
            throw IllegalArgumentException("$propertyName must be a valid absolute URL.", error)
        }

    require(uri.isAbsolute && !uri.host.isNullOrBlank()) {
        "$propertyName must be a valid absolute URL."
    }

    val scheme = uri.scheme.lowercase()
    require(scheme in allowedSchemes) {
        "$propertyName must use one of ${allowedSchemes.joinToString()}."
    }

    return normalized
}

fun Project.optionalValidatedUrlProperty(name: String, allowedSchemes: Set<String>): String? =
    (findProperty(name) as String?)
        ?.takeIf { it.isNotBlank() }
        ?.let { normalizeAndValidateBaseUrl(name, it, allowedSchemes) }

fun Project.requiredValidatedUrlProperty(name: String, allowedSchemes: Set<String>): String =
    optionalValidatedUrlProperty(name, allowedSchemes)
        ?: error("$name is required when FASTCHECK_API_TARGET selects this target.")

val requestedTasks = gradle.startParameter.taskNames.map { it.lowercase() }
val isReleaseTaskRequested = requestedTasks.any { it.contains("release") }
require(!isReleaseTaskRequested || fastcheckApiTarget == "release") {
    "Release tasks must use FASTCHECK_API_TARGET=release."
}

val releaseApiBaseUrl =
    project.optionalValidatedUrlProperty("FASTCHECK_API_BASE_URL_RELEASE", setOf("https"))
        ?: fixedReleaseApiBaseUrl

val devApiBaseUrl =
    project.optionalValidatedUrlProperty("FASTCHECK_API_BASE_URL_DEV", setOf("http", "https"))
        ?: ""

val deviceApiBaseUrl =
    project.optionalValidatedUrlProperty("FASTCHECK_API_BASE_URL_DEVICE", setOf("https"))
        ?: ""

val selectedApiBaseUrl =
    when (fastcheckApiTarget) {
        "dev" -> project.requiredValidatedUrlProperty("FASTCHECK_API_BASE_URL_DEV", setOf("http", "https"))
        "emulator" -> fixedEmulatorApiBaseUrl
        "device" -> project.requiredValidatedUrlProperty("FASTCHECK_API_BASE_URL_DEVICE", setOf("https"))
        else -> releaseApiBaseUrl
    }

plugins {
    id("com.android.application")
    id("com.google.devtools.ksp")
    id("com.google.dagger.hilt.android")
}

extensions.configure<ApplicationExtension>("android") {
    namespace = "za.co.voelgoed.fastcheck"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "za.co.voelgoed.fastcheck"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-scaffold"

        buildConfigField("String", "API_TARGET", "\"$fastcheckApiTarget\"")
        buildConfigField("String", "API_BASE_URL", "\"$selectedApiBaseUrl\"")
        buildConfigField("String", "SCANNER_SOURCE", "\"$fastcheckScannerSource\"")
        testInstrumentationRunner = "za.co.voelgoed.fastcheck.app.HiltTestRunner"
    }

    buildTypes {
        debug {
            buildConfigField("boolean", "ENABLE_HTTP_BASIC_LOGGING", "true")
        }
        release {
            isMinifyEnabled = false
            buildConfigField("boolean", "ENABLE_HTTP_BASIC_LOGGING", "false")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        buildConfig = true
        viewBinding = true
    }

    testOptions {
        unitTests.isIncludeAndroidResources = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }

    jvmToolchain(25)
}

dependencies {
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.activity:activity-ktx:1.10.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.datastore:datastore-preferences:1.1.1")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.room:room-runtime:2.8.4")
    implementation("androidx.room:room-ktx:2.8.4")
    ksp("androidx.room:room-compiler:2.8.4")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.hilt:hilt-work:1.3.0")
    ksp("androidx.hilt:hilt-compiler:1.3.0")
    implementation("com.google.dagger:hilt-android:2.59.2")
    ksp("com.google.dagger:hilt-compiler:2.59.2")
    implementation("com.squareup.retrofit2:retrofit:2.11.0")
    implementation("com.squareup.retrofit2:converter-moshi:2.11.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")
    implementation("com.squareup.moshi:moshi-kotlin:1.15.1")
    implementation("androidx.camera:camera-core:1.4.1")
    implementation("androidx.camera:camera-camera2:1.4.1")
    implementation("androidx.camera:camera-lifecycle:1.4.1")
    implementation("androidx.camera:camera-view:1.4.1")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("androidx.test:core:1.6.1")
    testImplementation("androidx.arch.core:core-testing:2.2.0")
    testImplementation("androidx.room:room-testing:2.8.4")
    testImplementation("androidx.work:work-testing:2.10.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("org.robolectric:robolectric:4.16.1")
    testImplementation("com.google.truth:truth:1.4.4")

    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("com.google.truth:truth:1.4.4")
    androidTestImplementation("com.google.dagger:hilt-android-testing:2.59.2")
    kspAndroidTest("com.google.dagger:hilt-compiler:2.59.2")
}
