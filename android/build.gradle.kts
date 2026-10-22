// The catzconnect plugin's Android module: the `catzconnect/attest` method
// channel for app keys (Google Play Integrity, classic request).
//
// Kotlin is applied the way fluttercommunity/plus_plugins does it, so the
// module builds with AGP 8 + the Kotlin Gradle plugin and with AGP 9's
// built-in Kotlin (unless the app sets android.builtInKotlin=false, which is
// what `flutter create` writes, and then KGP is applied here).

group = "com.catzconnect.sdk"
version = "2.0.0"

buildscript {
    val kotlinVersion = "2.2.0"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.12.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

val agpMajor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()

// AGP 9 provides Kotlin support natively unless the consuming app opts out
// with android.builtInKotlin=false.
val builtInKotlinEnabled =
    agpMajor >= 9 &&
        (providers.gradleProperty("android.builtInKotlin").orNull?.toBoolean() ?: true)

if (!builtInKotlinEnabled && !pluginManager.hasPlugin("org.jetbrains.kotlin.android")) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

project.extensions.configure(org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension::class.java) {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

android {
    namespace = "com.catzconnect.sdk"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // Same floor as flutter_webrtc / the README (Play Integrity itself
        // needs API 21).
        minSdk = 23
    }

    lint {
        disable.add("InvalidPackage")
    }
}

dependencies {
    // Google Play Integrity API (classic requests). 1.4.0 is the version
    // Firebase App Check and Expo App Integrity build against (Oct 2026).
    implementation("com.google.android.play:integrity:1.4.0")
}
