plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.harshkit.phonebridge"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.harshkit.phonebridge"
        minSdk = 33 // X25519 (XDH) needs Android 13+
        targetSdk = 35
        versionCode = 3
        versionName = "1.1.1"
    }
    // Release key lives outside the repo (~/.gradle/gradle.properties: PB_KEYSTORE, PB_KEYSTORE_PASSWORD).
    // Without it — e.g. a fresh clone — release builds fall back to the local debug key.
    val ks = providers.gradleProperty("PB_KEYSTORE").orNull
    signingConfigs {
        if (ks != null) create("release") {
            storeFile = file(ks)
            storePassword = providers.gradleProperty("PB_KEYSTORE_PASSWORD").get()
            keyAlias = "phonebridge"
            keyPassword = storePassword
        }
    }
    buildTypes { release { isMinifyEnabled = false; signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug") } }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
}
