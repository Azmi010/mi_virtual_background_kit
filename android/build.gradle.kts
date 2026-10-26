group = "com.azmi010.mi_virtual_background_kit"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
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

android {
    namespace = "com.azmi010.mi_virtual_background_kit"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            // android.util.Log etc. are stubs on the JVM; return defaults
            // instead of throwing in unit tests.
            isReturnDefaultValues = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // libwebrtc is pulled in by flutter_webrtc with `implementation`, so it is not on
    // this module's compile classpath. Declare it directly to compile against
    // org.webrtc.* types. Must stay in sync with the flutter_webrtc version.
    implementation("io.github.webrtc-sdk:android:150.7871.01")
    // Spike T0.6: segmentation engine candidates.
    implementation("com.google.mediapipe:tasks-vision:0.10.20")
    implementation("com.google.mediapipe:tasks-core:0.10.20")
    // Spike T0.6: ML Kit Selfie Segmentation (temporary, spike only).
    implementation("com.google.mlkit:segmentation-selfie:16.0.0-beta6")
    // MediaPipe links against Google's data transport runtime even though it
    // never uses it for anything but optional logging. The classes must stay
    // on the classpath or the engine fails to initialise, so the runtime is
    // kept but its network scheduling is disabled at startup in
    // SpikeSegmenterBenchmark.
    implementation("com.google.android.datatransport:transport-runtime:3.1.0")
    implementation("com.google.android.datatransport:transport-backend-cct:3.1.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
