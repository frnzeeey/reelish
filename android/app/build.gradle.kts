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

// Release APKs ship ARM code only. x86_64 libraries (libmpv, the torrent
// streamer, Flutter and app code) were about 54 MB of the APK, and every
// in-app update downloads the full file, while real x86_64 Android devices
// are rare. Debug builds keep x86_64 for emulator development. Flutter resets
// defaultConfig.ndk.abiFilters, so exclusion happens at packaging instead.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.add("lib/x86_64/**")
    }
}

// `flutter build apk --release` always names its output app-release.apk.
// Also publish it as flutter-apk/reelish.apk, the asset name the in-app
// updater looks for on GitHub Releases. This is a plain file copy on purpose:
// a Copy task would declare flutter-apk/ as its output and Gradle's stale
// output cleanup would delete Flutter's own APK from that directory.
val agpReleaseApk = layout.buildDirectory.file("outputs/apk/release/app-release.apk")
val reelishReleaseApk = layout.buildDirectory.file("outputs/flutter-apk/reelish.apk")

tasks.named { it == "assembleRelease" }.configureEach {
    doLast {
        val source = agpReleaseApk.get().asFile
        if (source.isFile) {
            source.copyTo(reelishReleaseApk.get().asFile, overwrite = true)
        }
    }
}
