package ai.arce.app.system

import ai.arce.core.engine.GenerateRequest
import ai.arce.core.engine.GenerationEvent
import ai.arce.core.engine.InferenceEngine
import ai.arce.core.engine.SamplingParams
import ai.arce.core.generation.FinishReason

data class BenchmarkResult(
    val promptTokens: Int,
    val promptSeconds: Double,
    val generatedPieces: Int,
    val generateSeconds: Double,
) {
    /** Approximate: the prompt is sized in tokens, output is counted in streamed pieces (~tokens). */
    val promptTokensPerSecond get() = promptTokens / promptSeconds
    val generateTokensPerSecond get() = generatedPieces / generateSeconds
}

/**
 * Measures prompt processing and token generation separately, like llama-bench (spec §29).
 * Runs only when the user asks.
 */
class Benchmark(private val engine: InferenceEngine) {
    suspend fun run(promptTokens: Int = 256, generateTokens: Int = 64): BenchmarkResult {
        // " a" is one token for Qwen tokenizers, so the prompt size is close to promptTokens
        val prompt = "<|im_start|>user\n" + " a".repeat(promptTokens) + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
        val request = GenerateRequest(prompt, null, thinking = false, maxTokens = generateTokens, sampling = SamplingParams.qwen3NonThinking)

        val start = System.nanoTime()
        var firstPieceAt = 0L
        var pieces = 0
        var reason = FinishReason.ERROR
        engine.generate(request).collect { event ->
            when (event) {
                is GenerationEvent.Piece -> {
                    if (pieces == 0) firstPieceAt = System.nanoTime()
                    pieces++
                }
                is GenerationEvent.Finished -> reason = event.reason
            }
        }
        val end = System.nanoTime()
        check(pieces > 1 && reason != FinishReason.ERROR) { "benchmark produced no output ($reason)" }
        return BenchmarkResult(
            promptTokens = promptTokens,
            promptSeconds = (firstPieceAt - start) / 1e9,
            generatedPieces = pieces - 1,
            generateSeconds = (end - firstPieceAt) / 1e9,
        )
    }
}
