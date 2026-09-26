package ai.arce.core.toolchain

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class BinaryManifestTest {
    private val bytes = BinaryManifest.launcherApp("com.example.hello", "Hello", "com.example.hello.MainActivity", 31, 36).toByteArray()
    private val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)

    @Test
    fun `file header covers the whole document`() {
        assertEquals(0x0003, buf.getShort(0).toInt())
        assertEquals(8, buf.getShort(2).toInt())
        assertEquals(bytes.size, buf.getInt(4))
        assertEquals(0, bytes.size % 4)
        // Written for manual checks with an independent parser (androguard) in development.
        System.getProperty("arce.axmlOut")?.let { File(it).writeBytes(bytes) }
    }

    @Test
    fun `string pool starts with the android attribute names in resource-id order`() {
        assertEquals(0x0001, buf.getShort(8).toInt())
        val poolSize = buf.getInt(12)
        val count = buf.getInt(16)
        val stringsStart = buf.getInt(28)
        fun string(i: Int): String {
            val at = 8 + stringsStart + buf.getInt(8 + 28 + i * 4)
            val len = buf.getShort(at).toInt()
            return String(CharArray(len) { buf.getChar(at + 2 + it * 2) })
        }
        assertEquals(
            listOf("label", "name", "exported", "minSdkVersion", "versionCode", "versionName", "targetSdkVersion"),
            (0 until 7).map(::string),
        )
        // The resource map follows the pool and lists the same attributes' ids.
        val map = 8 + poolSize
        assertEquals(0x0180, buf.getShort(map).toInt())
        assertEquals(7, (buf.getInt(map + 4) - 8) / 4)
        assertEquals(0x01010001, buf.getInt(map + 8))
        assertEquals(0x01010270, buf.getInt(map + 8 + 6 * 4))
        assertTrue(count > 7)
    }
}
