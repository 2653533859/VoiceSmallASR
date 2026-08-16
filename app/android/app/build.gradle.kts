plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

private val androidSigningVariables = listOf(
    "VSASR_ANDROID_KEYSTORE_FILE",
    "VSASR_ANDROID_KEY_ALIAS",
    "VSASR_ANDROID_KEYSTORE_PASSWORD",
    "VSASR_ANDROID_KEY_PASSWORD",
)

private val androidSigningRequested = androidSigningVariables.any { name ->
    !System.getenv(name).isNullOrBlank()
}

private fun requiredAndroidSigningValue(name: String): String =
    System.getenv(name)?.trim()?.takeUnless { it.isEmpty() }
        ?: error("$name is required when Android release signing is configured")

private val externalAndroidKeystorePath: String? =
    if (androidSigningRequested) requiredAndroidSigningValue("VSASR_ANDROID_KEYSTORE_FILE") else null

android {
    namespace = "com.voicesmallasr.vsasr_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.voicesmallasr.vsasr_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (externalAndroidKeystorePath != null) {
            create("releaseExternal") {
                val keystoreFile = project.file(externalAndroidKeystorePath!!)
                require(keystoreFile.isFile) {
                    "Android keystore file does not exist: ${keystoreFile.absolutePath}"
                }
                storeFile = keystoreFile
                storePassword = requiredAndroidSigningValue("VSASR_ANDROID_KEYSTORE_PASSWORD")
                keyAlias = requiredAndroidSigningValue("VSASR_ANDROID_KEY_ALIAS")
                keyPassword = requiredAndroidSigningValue("VSASR_ANDROID_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            // Without explicit credentials this remains a build-only artifact.
            // CI/release machines opt in with VSASR_ANDROID_* environment variables.
            signingConfig = if (externalAndroidKeystorePath != null) {
                signingConfigs.getByName("releaseExternal")
            } else {
                signingConfigs.getByName("debug")
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
