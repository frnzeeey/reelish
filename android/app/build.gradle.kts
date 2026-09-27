plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

fun releaseSigningValue(name: String): String? =
    providers.gradleProperty(name).orNull ?: System.getenv(name)

val releaseStoreFile = releaseSigningValue("ONFEED_RELEASE_STORE_FILE")
val releaseStorePassword = releaseSigningValue("ONFEED_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = releaseSigningValue("ONFEED_RELEASE_KEY_ALIAS")
val releaseKeyPassword = releaseSigningValue("ONFEED_RELEASE_KEY_PASSWORD")
val hasReleaseSigning = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
).all { !it.isNullOrBlank() }
val isReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}

if (isReleaseBuild && !hasReleaseSigning) {
    throw GradleException(
        "Release builds require a private keystore. Configure ONFEED_RELEASE_STORE_FILE, " +
            "ONFEED_RELEASE_STORE_PASSWORD, ONFEED_RELEASE_KEY_ALIAS, and " +
            "ONFEED_RELEASE_KEY_PASSWORD in Gradle properties or the environment."
    )
}

android {
    namespace = "com.example.onfeed"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.onfeed"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                null
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
