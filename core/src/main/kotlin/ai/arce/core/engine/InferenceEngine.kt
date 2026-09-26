package ai.arce.core.engine

import ai.arce.core.generation.FinishReason
import ai.arce.core.model.KvCacheType
import kotlinx.coroutines.flow.Flow

data class LoadParams(
    val path: String,
    val contextLength: Int = 4096,
    val threads: Int = 4,
    /** 0 = llama.cpp default. */
    val batchSize: Int = 0,
    val gpuLayers: Int = 0,
    val kvCache: KvCacheType = KvCacheType.F16,
)

data class SamplingParams(
    val temperature: Float,
    val topP: Float,
    val topK: Int,
    val minP: Float,
    /** 0 disables DRY; it discourages repeating earlier phrases (spec §55). */
    val dryMultiplier: Float = 0.8f,
) {
    companion object {
        // Qwen3 model card recommendations for each mode
        val qwen3Thinking = SamplingParams(temperature = 0.6f, topP = 0.95f, topK = 20, minP = 0f)
        val qwen3NonThinking = SamplingParams(temperature = 0.7f, topP = 0.8f, topK = 20, minP = 0f)
    }
}

data class GenerateRequest(
    val prompt: String,
    /** JSON Schema of an allowed tool call; null means the agent has no tools and no grammar is applied. */
    val toolCallSchema: String?,
    val thinking: Boolean,
    val maxTokens: Int,
    val sampling: SamplingParams,
    /** JSON Schema the whole output must match (no lazy trigger); used for short classifications. */
    val strictJsonSchema: String? = null,
)

sealed interface GenerationEvent {
    data class Piece(val text: String) : GenerationEvent
    data class Finished(val reason: FinishReason) : GenerationEvent
}

class EngineException(message: String) : Exception(message)

/**
 * Common surface of all inference backends (llama.cpp and LiteRT-LM),
 * so chat, agents and Generation Tasks never depend on a specific engine.
 */
interface InferenceEngine {
    val isLoaded: Boolean
    suspend fun load(params: LoadParams)
    fun generate(request: GenerateRequest): Flow<GenerationEvent>
    /** Stops the running generation from any thread. */
    fun cancel()
    suspend fun unload()
}
