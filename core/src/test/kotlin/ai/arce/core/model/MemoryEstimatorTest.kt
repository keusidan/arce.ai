package ai.arce.core.model

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class MemoryEstimatorTest {
    private val qwen14b = ModelCatalog.qwen3.single { it.displayName == "Qwen3-14B" }

    @Test
    fun `kv cache of Qwen3-14B at 16k context matches the spec review figure`() {
        // 2 x 40 layers x 8 heads x 128 dims x 2 bytes x 16384 tokens = 2.5 GiB
        assertEquals(2_684_354_560L, MemoryEstimator.kvCacheBytes(qwen14b, 16_384, KvCacheType.F16))
    }

    @Test
    fun `q8 kv cache roughly halves the cost`() {
        val f16 = MemoryEstimator.kvCacheBytes(qwen14b, 16_384, KvCacheType.F16)
        val q8 = MemoryEstimator.kvCacheBytes(qwen14b, 16_384, KvCacheType.Q8_0)
        assertTrue(q8 < f16 * 0.55)
    }

    @Test
    fun `greys out a model that does not fit`() {
        val gib = 1L shl 30
        assertFalse(MemoryEstimator.fits(qwen14b, 16_384, KvCacheType.F16, 8 * gib))
        assertTrue(MemoryEstimator.fits(qwen14b, 4_096, KvCacheType.F16, 16 * gib))
    }
}
