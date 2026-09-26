package ai.arce.core.model

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ModelCatalogTest {
    @Test
    fun `basic model is the small Qwen3_5 and fits a 4 GB phone`() {
        val basic = ModelCatalog.basic
        assertEquals(0.8, basic.paramsB)
        assertTrue(MemoryEstimator.fits(basic, 8192, KvCacheType.F16, 4_000_000_000L))
    }

    @Test
    fun `hybrid attention keeps the KV cache small`() {
        // 2 x 6 full-attention layers x 2 heads x 256 dims x 2 bytes x 4096 tokens = 48 MiB
        assertEquals(50_331_648L, MemoryEstimator.kvCacheBytes(ModelCatalog.basic, 4096, KvCacheType.F16))
    }

    @Test
    fun `ids and file names are unique`() {
        assertEquals(ModelCatalog.all.size, ModelCatalog.all.map { it.id }.toSet().size)
        assertEquals(ModelCatalog.all.size, ModelCatalog.all.map { it.fileName }.toSet().size)
    }

    @Test
    fun `lookup by file name and params parsing`() {
        assertSame(ModelCatalog.basic, ModelCatalog.byFileName("Qwen3.5-0.8B-Q8_0.gguf"))
        assertNull(ModelCatalog.byFileName("other.gguf"))
        assertEquals(1.7, ModelCatalog.byFileName("Qwen3-1.7B_dynamic_wi4b32_afp32.litertlm")?.paramsB)
        assertEquals(ModelFormat.LITERT_LM, ModelCatalog.byFileName("qwen3_4b_mixed_int4.litertlm")?.format)
    }
}
