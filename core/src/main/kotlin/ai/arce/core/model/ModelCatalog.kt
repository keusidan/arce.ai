package ai.arce.core.model

/**
 * A downloadable GGUF model.
 *
 * The hybrid Qwen3 releases are listed on purpose: they switch reasoning on and off per
 * turn. The later "-2507" releases split into Instruct and Thinking models and cannot.
 */
data class ModelSpec(
    val id: String,
    val displayName: String,
    val hfRepo: String,
    val fileName: String,
    val fileBytes: Long,
    val layers: Int,
    val kvHeads: Int,
    val headDim: Int,
    val thinking: ThinkingSupport,
)

enum class ThinkingSupport { SWITCHABLE, ALWAYS_ON, NONE }

enum class KvCacheType(val bytesPerElement: Double) { F16(2.0), Q8_0(1.0625) }

object ModelCatalog {
    private const val GB = 1_000_000_000L

    // Files from the official Qwen GGUF repos, sizes rounded. The 1.7B repo ships Q8_0 only.
    val qwen3 = listOf(
        ModelSpec("qwen3-1.7b-q8", "Qwen3-1.7B", "Qwen/Qwen3-1.7B-GGUF", "Qwen3-1.7B-Q8_0.gguf", (1.8 * GB).toLong(), 28, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-4b-q4km", "Qwen3-4B", "Qwen/Qwen3-4B-GGUF", "Qwen3-4B-Q4_K_M.gguf", (2.5 * GB).toLong(), 36, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-8b-q4km", "Qwen3-8B", "Qwen/Qwen3-8B-GGUF", "Qwen3-8B-Q4_K_M.gguf", (5.0 * GB).toLong(), 36, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-14b-q4km", "Qwen3-14B", "Qwen/Qwen3-14B-GGUF", "Qwen3-14B-Q4_K_M.gguf", (9.0 * GB).toLong(), 40, 8, 128, ThinkingSupport.SWITCHABLE),
    )
}

object MemoryEstimator {
    /** KV cache size: 2 (K and V) x layers x kv heads x head dim x bytes per element x tokens. */
    fun kvCacheBytes(model: ModelSpec, contextTokens: Int, type: KvCacheType): Long =
        (2.0 * model.layers * model.kvHeads * model.headDim * type.bytesPerElement * contextTokens).toLong()

    /** Weights are mmapped, so the whole file counts; compute buffers are left out of this estimate. */
    fun totalBytes(model: ModelSpec, contextTokens: Int, type: KvCacheType): Long =
        model.fileBytes + kvCacheBytes(model, contextTokens, type)

    /** Whether the model should be greyed out (spec §24/§60) unless Force Execution is on. */
    fun fits(model: ModelSpec, contextTokens: Int, type: KvCacheType, deviceRamBytes: Long): Boolean =
        totalBytes(model, contextTokens, type) <= deviceRamBytes
}
