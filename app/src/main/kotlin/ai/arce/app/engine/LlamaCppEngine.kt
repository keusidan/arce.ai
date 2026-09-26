package ai.arce.app.engine

import ai.arce.core.engine.EngineException
import ai.arce.core.engine.GenerateRequest
import ai.arce.core.engine.GenerationEvent
import ai.arce.core.engine.InferenceEngine
import ai.arce.core.engine.LoadParams
import ai.arce.core.generation.FinishReason
import ai.arce.core.model.KvCacheType
import java.util.concurrent.Executors
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext

class LlamaCppEngine : InferenceEngine {
    // llama.cpp contexts are not thread-safe: every call except cancel runs on this one thread.
    private val dispatcher = Executors.newSingleThreadExecutor { r -> Thread(r, "llama") }.asCoroutineDispatcher()

    @Volatile
    private var engine = 0L

    override val isLoaded: Boolean get() = engine != 0L

    override suspend fun load(params: LoadParams) = withContext(dispatcher) {
        if (engine != 0L) {
            LlamaNative.nativeFree(engine)
            engine = 0L
        }
        val handle = LlamaNative.nativeLoad(
            params.path,
            params.contextLength,
            params.threads,
            params.gpuLayers,
            params.kvCache == KvCacheType.Q8_0,
        )
        if (handle == 0L) throw EngineException(LlamaNative.nativeLastError())
        engine = handle
    }

    override fun generate(request: GenerateRequest): Flow<GenerationEvent> = flow {
        val handle = engine
        check(handle != 0L) { "no model loaded" }

        val session = LlamaNative.nativeStart(
            handle,
            request.prompt.toByteArray(Charsets.UTF_8),
            request.toolCallSchema,
            request.thinking,
            request.maxTokens,
            request.sampling.temperature,
            request.sampling.topP,
            request.sampling.topK,
            request.sampling.minP,
            request.sampling.dryMultiplier,
        )
        if (session == 0L) {
            val error = LlamaNative.nativeLastError()
            if (error == "cancelled") {
                emit(GenerationEvent.Finished(FinishReason.CANCELLED))
                return@flow
            }
            throw EngineException(error)
        }

        try {
            while (true) {
                currentCoroutineContext().ensureActive()
                val bytes = LlamaNative.nativeNext(session) ?: break
                // The native side only returns whole UTF-8 characters, so each piece decodes on its own.
                if (bytes.isNotEmpty()) emit(GenerationEvent.Piece(String(bytes, Charsets.UTF_8)))
            }
            emit(GenerationEvent.Finished(finishReason(LlamaNative.nativeFinishReason(session))))
        } finally {
            LlamaNative.nativeEnd(session)
        }
    }.flowOn(dispatcher)

    override fun cancel() {
        val handle = engine
        if (handle != 0L) LlamaNative.nativeCancel(handle)
    }

    override suspend fun unload() = withContext(dispatcher) {
        if (engine != 0L) {
            LlamaNative.nativeFree(engine)
            engine = 0L
        }
    }

    private fun finishReason(code: Int): FinishReason = when (code) {
        0 -> FinishReason.EOG
        1 -> FinishReason.LENGTH
        2 -> FinishReason.CANCELLED
        else -> FinishReason.ERROR
    }
}
