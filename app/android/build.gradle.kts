allprojects {
    repositories {
        google()
        mavenCentral()
        maven { url = uri("https://jitpack.io") }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// §380 — build-id нативных .so отключён ради воспроизводимости.
//
// NDK по умолчанию передаёт `-Wl,--build-id=sha1` всем CMake-сборкам
// (`build/cmake/flags.cmake:72` — обход старого LLDB в Android Studio).
// Название вводит в заблуждение: LLD хэширует выходной файл ДО strip —
// вместе с отладочной информацией, где сидят абсолютные пути сборки. В
// поставляемый `.so` эта информация не попадает, поэтому два прогона одного
// кода в разных окружениях дают разный отпечаток при совпадающих `.so`.
//
// Измерено на `libdartjni.so` (v2.20.1, F-Droid против GitHub): файлы
// различаются РОВНО на 20 байт — сам build-id по смещению 0x2e0. Таблицы
// секций, `.text`, `.rodata`, всё остальное — идентичны побайтово.
//
// Такой build-id бесполезен и для отладки: он меняется без изменения кода,
// значит по нему всё равно не найти нужные символы. `none` убирает секцию
// целиком — так делают и приложения каталога F-Droid, собирающие ZXing.
//
// Задано здесь, а не в метаданных F-Droid: их сборка использует этот же
// файл, поэтому один источник работает на обе стороны.
//
// ⚠ `-DCMAKE_SHARED_LINKER_FLAGS` задаёт cache-переменную целиком, поэтому
// результат проверен сборкой, а не выведен из документации (v2.20.2 против
// v2.20.3, `libdartjni.so`):
//   • `llvm-readelf -n` — секции `.note.gnu.build-id` нет ⇒ дефолт NDK не
//     побеждает как последний в строке;
//   • набор секций не изменился, `.dynamic`/`.got.plt`/`.rela.plt` на месте
//     и того же размера ⇒ init-флаги NDK не затёрты.
// Различаются только адреса в `.text`/`.plt`/`.rela.*` — сдвиг от удалённой
// секции, размеры совпадают до байта. Файл легче на 136 байт (36 секции +
// выравнивание + `.shstrtab` 245→226).
//
// Если механизм когда-нибудь перестанет работать, гарантированная замена —
// патч `add_link_options("LINKER:--build-id=none")` в `CMakeLists.txt`
// самого пакета (так делает рецепт F-Droid для zxing у других приложений).
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.dsl.LibraryExtension>("android") {
            defaultConfig {
                externalNativeBuild {
                    cmake {
                        arguments += "-DCMAKE_SHARED_LINKER_FLAGS=-Wl,--build-id=none"
                    }
                }
            }
        }
    }
}

// AGP 9 + `android.builtInKotlin=false`: плагины, которые на AGP ≥ 9 сами
// НЕ подключают `org.jetbrains.kotlin.android` в расчёте на встроенный Kotlin
// (file_picker 11.x: `if (!isAgp9OrAbove) apply plugin: ...`), остаются без
// компилятора Kotlin — их классы не собираются, и `GeneratedPluginRegistrant`
// падает на `cannot find symbol FilePickerPlugin`. Встроенный Kotlin включить
// нельзя, пока остальные плагины (camera_android_camerax, device_info_plus,
// share_plus, …) применяют KGP сами — с ним они конфликтуют. Поэтому KGP
// таким плагинам подключаем отсюда. Снять, когда включим встроенный Kotlin.
val pluginsNeedingKgp = setOf("file_picker")
subprojects {
    if (name !in pluginsNeedingKgp) return@subprojects
    plugins.withId("com.android.library") {
        if (!plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            plugins.apply("org.jetbrains.kotlin.android")
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension>("kotlin") {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
