package com.arce.ai

import java.util.concurrent.atomic.AtomicBoolean

/**
 * JNI bridge to libarce_llama.so (llama.cpp @d81aef1, CPU + optional Vulkan GPU).
 * One model at a time. Generation is synchronous on the calling thread;
 * ChatEngine calls it from Dispatchers.IO.
 */
object ArceLlama {

    @Volatile
    var loadError: String? = null
        private set

    @Volatile
    var isModelLoaded: Boolean = false
        private set

    @Volatile
    var modelInfo: String = ""
        private set

    private val stopping = AtomicBoolean(false)

    init {
        try {
            System.loadLibrary("arce_llama")
        } catch (e: Throwable) {
            loadError = "ネイティブライブラリの読み込みに失敗: ${e.message}"
        }
    }

    interface TokenCallback {
        fun onToken(piece: String)
        fun onDone(fullText: String, errorMsg: String?)
    }

    // --- native ---
    private external fun nativeInitModel(path: String, gpuLayers: Int, nCtx: Int, threads: Int): Int
    private external fun nativeFreeModel()
    private external fun nativeBackends(): String
    private external fun nativeGenerate(prompt: String, maxTokens: Int, temp: Float, penalty: Float, cb: TokenCallback): Int
    private external fun nativeStop()

    fun backends(): List<BackendInfo> {
        if (loadError != null) return emptyList()
        return try {
            val s = nativeBackends()
            if (s.isNullOrEmpty() || s == "none") {
                listOf(BackendInfo("CPU (未検出)", "cpu"))
            } else {
                s.split(";").filter { it.isNotBlank() }.map {
                    val parts = it.split("|")
                    val type = if (it.contains("Vulkan", ignoreCase = true) || parts.getOrNull(1) == "gpu") "gpu" else "cpu"
                    BackendInfo(parts.first(), type)
                }
            }
        } catch (e: Throwable) {
            listOf(BackendInfo("CPU (例外: ${e.message})", "cpu"))
        }
    }

    fun initModel(path: String, gpuLayers: Int, nCtx: Int, threads: Int): Boolean {
        if (loadError != null) return false
        return try {
            val rc = nativeInitModel(path, gpuLayers, nCtx, threads)
            isModelLoaded = rc == 0
            if (!isModelLoaded) modelInfo = ""
            isModelLoaded
        } catch (e: Throwable) {
            loadError = "モデル初期化例外: ${e.message}"
            false
        }
    }

    fun freeModel() {
        if (loadError != null) return
        try {
            nativeFreeModel()
        } catch (_: Throwable) {
        }
        isModelLoaded = false
        modelInfo = ""
    }

    fun stop() {
        try {
            nativeStop()
        } catch (_: Throwable) {
        }
    }

    fun generate(
        prompt: String,
        maxTokens: Int,
        temp: Float,
        penalty: Float,
        cb: TokenCallback
    ): Boolean {
        if (!isModelLoaded) return false
        stopping.set(false)
        return try {
            nativeGenerate(prompt, maxTokens, temp, penalty, cb) == 0
        } catch (e: Throwable) {
            cb.onDone("", "生成中に例外: ${e.message}")
            false
        }
    }

    fun isStopping(): Boolean = stopping.get()
}
