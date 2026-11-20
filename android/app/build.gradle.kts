import java.util.Properties
import javax.inject.Inject

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Release builds pass the version from the git tag (vX.Y.Z), like the Windows app; local builds are
// "dev" builds that never offer updates.
val appVersion = (project.findProperty("versionName") as String?) ?: "dev"
val appVersionCode = appVersion.split(".").mapNotNull { it.toIntOrNull() }.let { p ->
    if (p.size == 3) p[0] * 10000 + p[1] * 100 + p[2] else 1
}

android {
    namespace = "io.github.mybugga.litewallpaper"
    compileSdk = 36

    defaultConfig {
        applicationId = "io.github.mybugga.litewallpaper"
        minSdk = 26
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersion
    }

    // Release signing comes from the environment (CI secrets) or from ../.local/signing.properties;
    // without either, release builds are signed with the debug key.
    val signing = rootProject.file("../.local/signing.properties").takeIf { it.exists() }?.let { f ->
        Properties().apply { f.inputStream().use { load(it) } }
    }
    val storeFile = System.getenv("ANDROID_KEYSTORE_FILE") ?: signing?.getProperty("storeFile")
    signingConfigs {
        if (storeFile != null) {
            create("release") {
                this.storeFile = rootProject.file(storeFile)
                storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD") ?: signing?.getProperty("storePassword")
                keyAlias = System.getenv("ANDROID_KEY_ALIAS") ?: signing?.getProperty("keyAlias")
                keyPassword = System.getenv("ANDROID_KEY_PASSWORD") ?: signing?.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    buildFeatures {
        compose = true
    }

    androidResources {
        // The pictures are already compressed (JPEG/PNG/WebP); storing them as-is keeps loading fast.
        noCompress += listOf("jpg", "png", "webp")
    }
}

// The wallpapers' pictures and particle presets come straight from the Windows app's folders, so
// there's one copy of each in the repository.
abstract class WallpaperAssets : DefaultTask() {
    @get:InputDirectory abstract val pictures: DirectoryProperty
    @get:InputDirectory abstract val particles: DirectoryProperty
    @get:OutputDirectory abstract val output: DirectoryProperty
    @get:Inject abstract val files: FileSystemOperations

    @TaskAction
    fun copy() {
        files.sync {
            from(pictures) { into("shaders/assets") }
            from(particles) { into("particles") }
            into(output)
        }
    }
}

val wallpaperAssets = tasks.register<WallpaperAssets>("wallpaperAssets") {
    pictures.set(rootProject.layout.projectDirectory.dir("../shaders/assets"))
    particles.set(rootProject.layout.projectDirectory.dir("../particles"))
}
androidComponents {
    onVariants { variant ->
        variant.sources.assets?.addGeneratedSourceDirectory(wallpaperAssets, WallpaperAssets::output)
    }
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.compose.ui:ui-tooling-preview")
    debugImplementation("androidx.compose.ui:ui-tooling")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
