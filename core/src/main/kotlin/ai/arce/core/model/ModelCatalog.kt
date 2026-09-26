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
    val format: ModelFormat = ModelFormat.GGUF,
    /** Set for NPU builds, which only run on the SoC they were compiled for (e.g. "mt6993"). */
    val npuSoc: String? = null,
) {
    /** "Qwen3.5-0.8B" -> 0.8 */
    val paramsB: Double? get() = Regex("(\\d+(?:\\.\\d+)?)B$").find(displayName.substringBefore(" "))?.groupValues?.get(1)?.toDoubleOrNull()
}

/** GGUF runs on llama.cpp; LiteRT-LM files run on LiteRT-LM (CPU, GPU or NPU). */
enum class ModelFormat { GGUF, LITERT_LM }

enum class ThinkingSupport { SWITCHABLE, ALWAYS_ON, NONE }

enum class KvCacheType(val bytesPerElement: Double) { F16(2.0), Q8_0(1.0625) }

object ModelCatalog {
    private const val GB = 1_000_000_000L

    // Sizes are the exact byte counts published on Hugging Face (verified again by SHA-256 on download).
    // Qwen3.5 is hybrid: only every 4th layer (6 of 24) keeps a KV cache, 2 KV heads x 256 dims.
    val basic = ModelSpec(
        "qwen3.5-0.8b-q8", "Qwen3.5-0.8B", "ggml-org/Qwen3.5-0.8B-GGUF", "Qwen3.5-0.8B-Q8_0.gguf",
        833_592_096L, 6, 2, 256, ThinkingSupport.SWITCHABLE,
    )

    // The hybrid Qwen3 releases switch reasoning per turn. The 1.7B repo ships Q8_0 only.
    val qwen3 = listOf(
        ModelSpec("qwen3-0.6b-q8", "Qwen3-0.6B", "Qwen/Qwen3-0.6B-GGUF", "Qwen3-0.6B-Q8_0.gguf", 639_446_688L, 28, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-1.7b-q8", "Qwen3-1.7B", "Qwen/Qwen3-1.7B-GGUF", "Qwen3-1.7B-Q8_0.gguf", (1.8 * GB).toLong(), 28, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-4b-q4km", "Qwen3-4B", "Qwen/Qwen3-4B-GGUF", "Qwen3-4B-Q4_K_M.gguf", (2.5 * GB).toLong(), 36, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-8b-q4km", "Qwen3-8B", "Qwen/Qwen3-8B-GGUF", "Qwen3-8B-Q4_K_M.gguf", (5.0 * GB).toLong(), 36, 8, 128, ThinkingSupport.SWITCHABLE),
        ModelSpec("qwen3-14b-q4km", "Qwen3-14B", "Qwen/Qwen3-14B-GGUF", "Qwen3-14B-Q4_K_M.gguf", (9.0 * GB).toLong(), 40, 8, 128, ThinkingSupport.SWITCHABLE),
    )

    // LiteRT-LM builds from litert-community. The MediaTek file is an NPU build for Dimensity (mt6993) only.
    val liteRt = listOf(
        ModelSpec("litert-qwen3-0.6b", "Qwen3-0.6B LiteRT", "litert-community/Qwen3-0.6B", "Qwen3-0.6B.litertlm", 614_236_160L, 28, 8, 128, ThinkingSupport.SWITCHABLE, ModelFormat.LITERT_LM),
        ModelSpec("litert-qwen3-0.6b-mt6993", "Qwen3-0.6B LiteRT NPU", "litert-community/Qwen3-0.6B", "Qwen3-0.6B.mediatek.mt6993.litertlm", 1_202_913_280L, 28, 8, 128, ThinkingSupport.SWITCHABLE, ModelFormat.LITERT_LM, npuSoc = "mt6993"),
        ModelSpec("litert-qwen3-1.7b-int4", "Qwen3-1.7B LiteRT", "litert-community/Qwen3-1.7B", "Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm", 977_184_032L, 28, 8, 128, ThinkingSupport.SWITCHABLE, ModelFormat.LITERT_LM),
        ModelSpec("litert-qwen3-4b-int4", "Qwen3-4B LiteRT", "litert-community/Qwen3-4B", "qwen3_4b_mixed_int4.litertlm", 2_659_057_664L, 36, 8, 128, ThinkingSupport.SWITCHABLE, ModelFormat.LITERT_LM),
    )

    val all: List<ModelSpec> = listOf(basic) + qwen3 + liteRt

    fun byFileName(name: String): ModelSpec? = all.firstOrNull { it.fileName == name }
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
