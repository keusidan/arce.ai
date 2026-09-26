plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.chaquopy)
}

// Release signing comes from the environment (GitHub Actions secrets, see
// docs/ARCE_AI_release-workflow_*.md). Without it, assembleRelease produces an unsigned APK.
val releaseKeystore: String? = System.getenv("ARCE_KEYSTORE_PATH")
val releasePassword: String? = System.getenv("ARCE_KEYSTORE_PASSWORD")
val releaseKeyAlias: String? = System.getenv("ARCE_KEY_ALIAS")
val hasReleaseSigning = listOf(releaseKeystore, releasePassword, releaseKeyAlias).all { !it.isNullOrEmpty() }

android {
    namespace = "ai.arce.app"
    compileSdk = 36
    ndkVersion = "29.0.13113456"

    defaultConfig {
        applicationId = "ai.arce.app"
        // Android 12 (2021) through the current release: "latest minus five years"
        minSdk = 31
        targetSdk = 36
        // CI passes -Parce.versionCode=<run number> and -Parce.versionName=<tag without "v">.
        // versionCode must only grow, or Android refuses the update.
        versionCode = providers.gradleProperty("arce.versionCode").orNull?.toInt() ?: 1
        versionName = providers.gradleProperty("arce.versionName").orNull ?: "0.1.0-dev"

        ndk {
            abiFilters += "arm64-v8a"
        }
        externalNativeBuild {
            cmake {
                arguments += "-DCMAKE_BUILD_TYPE=Release"
                arguments += "-DGGML_VULKAN=${if (project.property("arce.ggml.vulkan") == "true") "ON" else "OFF"}"
                arguments += "-DGGML_OPENCL=${if (project.property("arce.ggml.opencl") == "true") "ON" else "OFF"}"
                // Reuse compiled objects between builds (CI sets -Parce.ccache=true; needs ccache on PATH)
                if (providers.gradleProperty("arce.ccache").orNull == "true") {
                    arguments += "-DCMAKE_C_COMPILER_LAUNCHER=ccache"
                    arguments += "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache"
                }
            }
        }
    }

    externalNativeBuild {
        cmake {
            path("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseKeystore!!)
                // keytool's default PKCS12 keystores use one password for the store and the key
                storePassword = releasePassword
                keyAlias = releaseKeyAlias
                keyPassword = releasePassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (hasReleaseSigning) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        jniLibs {
            // Store .so files uncompressed and page-aligned so they load straight from the APK.
            useLegacyPackaging = false
            // LiteRT-LM and Chaquopy may both bring the shared C++ runtime.
            pickFirsts += "**/libc++_shared.so"
        }
        resources {
            // Jar metadata of ECJ / R8 / apksig that nothing reads at runtime and that collides.
            excludes += listOf("META-INF/*.SF", "META-INF/*.RSA", "META-INF/*.DSA", "META-INF/eclipse.inf",
                "META-INF/versions/**", "META-INF/LICENSE*", "META-INF/NOTICE*", "about.html", "about_files/**")
        }
    }
}

// Python for the code runner (Chaquopy). No pip packages, so no build-time Python is needed.
chaquopy {
    defaultConfig {
        version = "3.13"
        pyc {
            src = false
        }
    }
}

// The on-device Java compiler (ECJ) and dexer (D8) need the Android class library to compile
// against. Ship the SDK's android.jar (classes only) as an asset.
val androidJarAsset = tasks.register<Zip>("androidJarAsset") {
    from(zipTree(android.sdkDirectory.resolve("platforms/android-${android.compileSdk}/android.jar"))) {
        include("**/*.class")
    }
    archiveFileName.set("android.jar")
    destinationDirectory.set(layout.buildDirectory.dir("generated/arceAssets"))
    isPreserveFileTimestamps = false
    isReproducibleFileOrder = true
}

androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(androidJarAsset, Zip::getDestinationDirectory)
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":core"))

    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.coroutines.android)
    implementation(libs.androidx.datastore.preferences)
    implementation(libs.androidx.room.runtime)
    implementation(libs.androidx.room.ktx)
    ksp(libs.androidx.room.compiler)
    implementation(libs.androidx.webkit)
    implementation(libs.androidx.work.runtime)
    implementation(libs.litertlm.android)
    implementation(libs.ecj)
    implementation(libs.r8)
    implementation(libs.apksig)

    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui.tooling.preview)
    debugImplementation(libs.androidx.compose.ui.tooling)
}
