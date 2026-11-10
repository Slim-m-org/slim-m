import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// key.properties is gitignored (public repo, CI writes it from secrets). Without
// it, release builds debug-sign so a contributor's `flutter run --release` works.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(keystorePropertiesFile.inputStream())
    // Present but incomplete means CI wrote a malformed secret; unchecked, that
    // silently debug-signs a release and nothing downstream reliably catches it.
    val required = listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
    val absent = required.filter { keystoreProperties[it]?.toString().isNullOrBlank() }
    require(absent.isEmpty()) {
        "key.properties exists but is missing: $absent. Refusing to fall back " +
            "to debug signing for a release build."
    }
}

// Conditional because google-services.json is gitignored (public repo, API
// key); applying it always breaks contributors. See FirebaseFcmTokenSource.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

android {
    namespace = "top.npcserver.slimm"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // flutter_local_notifications uses java.time APIs native only to API
        // 26+; desugaring is what keeps it working down to this app's minSdk.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "top.npcserver.slimm"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Otherwise a release ships the class and method names of a
            // messaging client: a free map of the auth and push paths.
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Required by isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
