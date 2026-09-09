plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

import java.io.FileInputStream
import java.util.Properties

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun hasReleaseKeystore(): Boolean =
    keystorePropertiesFile.exists() &&
        !keystoreProperties.getProperty("storeFile").isNullOrBlank()

android {
    namespace = "com.leadaxe.lxbox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }

    // §380 — AGP по умолчанию вшивает в APK блок `DEPENDENCY METADATA`: список
    // зависимостей, зашифрованный публичным ключом Google. Читать его умеет
    // только Play Console, поэтому сканер F-Droid считает его непрозрачными
    // данными и отвергает APK целиком («Found extra signing block»).
    //
    // Лежит он в APK Signing Block — ВНЕ zip-структуры, поэтому пофайловое
    // сравнение архивов его не видит: 455 файлов совпадали, а верификация
    // всё равно падала (7185 байт, id 0x504b4453 в v2.20.4).
    //
    // Для AAB оставлено включённым — Google Play собирается из бандла, и там
    // эти данные дают предупреждения об уязвимых библиотеках.
    dependenciesInfo {
        includeInApk = false
        includeInBundle = true
    }

    defaultConfig {
        applicationId = "com.leadaxe.lxbox"
        // Android 7.0 (API 24) minimum — §233. Это абсолютный пол: Flutter
        // 3.41.x поддерживает минимум API 24, libbox.aar требует 23.
        // Приоритет тестирования и поддержки — 11+ (primary target window).
        //
        // Tiers:
        //   - Primary (11+, API 30+)  — все фичи, тестируется.
        //   - Best-effort (7.0-10, API 24-29) — compile/install OK, фичи
        //     новых API деградируют за SDK_INT-гейтами. Например, silent-kill
        //     detection (getHistoricalProcessExitReasons, API 30+) — no-op.
        //   - Unsupported (<7.0, API <24) — install blocked (пол Flutter).
        //
        // Known limitation 7.x: старый системный trust store (на 7.0 нет
        // ISRG Root X1 → Let's Encrypt-подписки не валидируются).
        // См. ARCHITECTURE.md → Supported platforms и docs/spec/tasks/233.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ABI filter (build-size optimization). Flutter `--target-platform`
        // влияет только на свой engine + Dart AOT; нативные .so из Maven
        // (libbox 1.13 — 55-66 MB per ABI) gradle подтягивает для всех
        // ABI, и APK раздувается до ~76MB.
        //
        // Сужаем через переменную окружения `LXBOX_ABI_FILTER` (выставляется
        // в scripts/build-local-apk.sh). `-P` props из flutter build не
        // пробрасываются стабильно, env-var универсально срабатывает.
        // Если var не задан — поведение не меняется (CI-сборка по
        // умолчанию остаётся универсальной, как раньше).
    }

    // ABI filter (build-size optimization). Flutter gradle plugin по
    // умолчанию выставляет `ndk.abiFilters` для всех 3 ABI
    // (armeabi-v7a, arm64-v8a, x86_64) — даже если передан
    // `--target-platform android-arm64` это влияет только на flutter engine
    // и Dart AOT, native libs из Maven AAR (libbox 55-66 MB / ABI)
    // подтягиваются под все 3.
    //
    // Очищаем `ndk.abiFilters` и задаём только нужный ABI через env-var
    // `LXBOX_ABI_FILTER` (выставляется в scripts/build-local-apk.sh).
    // Если var не задан — поведение не меняется (CI-сборка остаётся
    // универсальной для всех 3 ABI).
    val abiFilterEnv: String? = System.getenv("LXBOX_ABI_FILTER")
    if (!abiFilterEnv.isNullOrBlank()) {
        val keepAbis = abiFilterEnv.split(",").map { it.trim() }.toSet()
        defaultConfig.ndk.abiFilters.clear()
        defaultConfig.ndk.abiFilters.addAll(keepAbis)
        // Дополнительно: исключаем JNI-libs других ABI из AAR (libbox).
        // `ndk.abiFilters` контролирует только локально-собранные .so;
        // AAR-вложенные .so отфильтровываются именно `packaging.jniLibs.excludes`.
        val allAbis = setOf("armeabi-v7a", "arm64-v8a", "x86_64", "x86")
        val excludeAbis = allAbis - keepAbis
        packaging {
            for (abi in excludeAbis) {
                jniLibs.excludes += "lib/$abi/**"
            }
        }
    }

    signingConfigs {
        if (hasReleaseKeystore()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")!!
                keyPassword = keystoreProperties.getProperty("keyPassword")!!
                storePassword = keystoreProperties.getProperty("storePassword")!!
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile")!!)
            }
        }
    }

    buildTypes {
        release {
            signingConfig =
                if (hasReleaseKeystore()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
                }
        }
    }

    packaging {
        jniLibs { useLegacyPackaging = true }
    }
}

dependencies {
    // §104 — ядро: собственный fork sing-box-lx (AWG2 + XHTTP, §097).
    // AAR не в git (~73MB, libs/ в .gitignore): его кладёт
    // scripts/fetch-libbox.sh (пин версии — app/android/libbox.version),
    // вызывается из build-local-apk.sh и CI (ci.yml → "Fetch sing-box-lx core").
    implementation(files("libs/libbox.aar"))
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.7.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
}

flutter {
    source = "../.."
}
