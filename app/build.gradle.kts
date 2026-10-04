plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.arce.ai"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.arce.ai"
        minSdk = 26
        targetSdk = 34
        versionCode = 1
        versionName = "1.0.0-full"
    }

    signingConfigs {
        create("release") {
            // Local build keystore (committed, for this project's self-signed release)
            val ksFile = rootProject.file("keystore/arce-release.jks")
            storeFile = ksFile.takeIf { it.exists() }
            storePassword = System.getenv("ARCE_KS_PASS") ?: "arce2026"
            keyAlias = "arce"
            keyPassword = System.getenv("ARCE_KS_PASS") ?: "arce2026"
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        compose = true
    }
    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }
    packaging {
        resources.excludes += "/META-INF/{AL2.0,LGPL2.1}"
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.4")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.navigation:navigation-compose:2.7.7")

    val composeBom = platform("androidx.compose:compose-bom:2024.05.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    debugImplementation("androidx.compose.ui:ui-tooling")

    // Embedded lightweight HTTP server (artifact local preview)
    implementation("org.nanohttpd:nanohttpd:2.3.1")
    // HTML parsing for web search results
    implementation("org.jsoup:jsoup:1.17.2")
    // Background work + notifications
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
}
