package ai.arce.app.engine

/**
 * Raw JNI surface of libarce_llama.so (app/src/main/cpp/arce_llama.cpp).
 * Handles are native pointers; use [LlamaCppEngine] instead of calling these directly.
 */
internal object LlamaNative {
    init {
        System.loadLibrary("arce_llama")
        nativeBackendInit()
    }

    external fun nativeBackendInit()
    external fun nativeLastError(): String
    external fun nativeSchemaToGrammar(schemaJson: String): String?

    /** Returns an engine handle, or 0 on failure (see [nativeLastError]). */
    external fun nativeLoad(path: String, nCtx: Int, nThreads: Int, nGpuLayers: Int, kvQ8: Boolean): Long
    external fun nativeFree(engine: Long)

    /** Returns a session handle, or 0 on failure. [promptUtf8] is UTF-8 because JNI strings cannot carry emoji. */
    external fun nativeStart(
        engine: Long,
        promptUtf8: ByteArray,
        toolSchema: String?,
        thinking: Boolean,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        topK: Int,
        minP: Float,
        dryMultiplier: Float,
    ): Long

    /** Next UTF-8 piece (may be empty), or null when finished. */
    external fun nativeNext(session: Long): ByteArray?
    external fun nativeFinishReason(session: Long): Int
    /** Safe to call from any thread; also aborts a prompt that is still being evaluated. */
    external fun nativeCancel(engine: Long)
    external fun nativeEnd(session: Long)
}
