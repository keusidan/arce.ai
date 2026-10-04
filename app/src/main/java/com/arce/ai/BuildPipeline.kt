package com.arce.ai

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import java.io.File

/**
 * On-device build attempts (APK/EXE/JAR) per 企画書:
 * real environment probe + progress + missing-environment report into the chat.
 * EXE explicitly requires a PC build server.
 */
class BuildPipeline(private val app: ArceApp) {

    suspend fun run(target: String, onProgress: (String) -> Unit): BuildReport =
        withContext(Dispatchers.IO) { doRun(target, onProgress) }

    private suspend fun doRun(target: String, onProgress: (String) -> Unit): BuildReport {
        val sb = StringBuilder()
        fun log(s: String) {
            sb.appendLine(s)
            onProgress(s)
            delay(150)
        }

        when (target) {
            "apk" -> {
                log("=== APK ビルド（端末内）開始 ===")
                log("環境検査: JDK / Gradle / Android SDK を確認しています...")
                val missing = mutableListOf<String>()
                if (!which("java")) missing += "JDK (java)"
                if (!which("gradle")) missing += "Gradle"
                if (System.getenv("ANDROID_HOME").isNullOrBlank()) missing += "Android SDK (ANDROID_HOME)"
                if (missing.isNotEmpty()) {
                    log("不足があるツール: " + missing.joinToString("、"))
                    log("端末内ではビルド環境が揃っていません。PCの development 環境で")
                    log("scripts/build_native.sh → gradle :app:assembleRelease を実行してください。")
                    return@withContext BuildReport("apk", false, sb.toString(), missing)
                }
                log("環境OK。gradle :app:assembleRelease を実行しています...")
                try {
                    val pb = ProcessBuilder("gradle", ":app:assembleRelease")
                        .directory(File(app.cacheDir, "build-work"))
                        .redirectErrorStream(true)
                    pb.directory.mkdirs()
                    val p = pb.start()
                    val out = p.inputStream.bufferedReader().readText()
                    val code = p.waitFor()
                    if (code == 0) {
                        log("BUILD SUCCESSFUL（シミュレート検出: 端末内にリポジトリがないため、")
                        log("PCでのビルドを推奨します）")
                        return@withContext BuildReport("apk", true, sb.toString(), emptyList())
                    } else {
                        log("ビルド失敗 (code=$code)")
                        log(out.take(500))
                        return@withContext BuildReport("apk", false, sb.toString(), listOf("gradle build failed"))
                    }
                } catch (e: Exception) {
                    log("実行例外: ${e.message}")
                    return@withContext BuildReport("apk", false, sb.toString(), listOf(e.message ?: "exec failed"))
                }
            }

            "exe" -> {
                log("=== EXE（Windows PC）ビルド ===")
                log("EXEビルドはPCビルドサーバー必須です（企画書準拠）。")
                log("本アプリ内でEXEを生成することはできません。")
                log("Windows PC 上で CMake + MSVC を用意し、native/ (arm64→x64 Windows) をビルドしてください。")
                return@withContext BuildReport(
                    "exe", false, sb.toString(), listOf("Windows PC (CMake + MSVC)")
                )
            }

            "jar" -> {
                log("=== JAR ビルド（端末内）開始 ===")
                log("環境検査: JDK (javac/jar) を確認しています...")
                val missing = mutableListOf<String>()
                if (!which("java")) missing += "JDK (java)"
                if (!which("javac")) missing += "JDK (javac)"
                if (!which("jar")) missing += "JDK (jar)"
                if (missing.isNotEmpty()) {
                    log("不足があるツール: " + missing.joinToString("、"))
                    log("PCのJDK環境で jar を作成してください。")
                    return@withContext BuildReport("jar", false, sb.toString(), missing)
                }
                log("JDKは利用可能ですが、この端末にはJavaソースが含まれていません。")
                log("PCで git pull して jar をビルドしてください。")
                return@withContext BuildReport("jar", false, sb.toString(), listOf("java sources on device"))
            }

            else -> {
                log("不明なターゲット: $target")
                return@withContext BuildReport(target, false, sb.toString(), listOf("unknown target"))
            }
        }
    }

    private fun which(bin: String): Boolean = try {
        val p = ProcessBuilder("which", bin).redirectErrorStream(true).start()
        p.inputStream.bufferedReader().readText().trim().isNotEmpty() && p.waitFor() == 0
    } catch (_: Exception) {
        false
    }
}
