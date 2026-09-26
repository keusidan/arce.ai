package ai.arce.core.update

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class ReleasesTest {
    @Test
    fun `versions compare numerically and pre-releases sort first`() {
        assertTrue(Version.parse("v0.1.10")!! > Version.parse("0.1.9")!!)
        assertTrue(Version.parse("1.0.0")!! > Version.parse("1.0.0-beta")!!)
        assertEquals(Version(0, 1, 0, "dev"), Version.parse("0.1.0-dev"))
        assertNull(Version.parse("latest"))
    }

    @Test
    fun `release json yields apk and checksum assets`() {
        val release = ReleaseParser.parse(
            """{"tag_name":"v0.1.1","body":"notes","assets":[
               {"id":1,"name":"ARCE.AI-v0.1.1.apk","size":10117153},
               {"id":2,"name":"ARCE.AI-v0.1.1.apk.sha256","size":85}]}""",
        )!!
        assertEquals(Version(0, 1, 1), release.version)
        assertEquals(1L, release.apk!!.id)
        assertEquals(2L, release.checksum!!.id)
        assertEquals("ab".repeat(32), ReleaseParser.parseChecksum("${"ab".repeat(32)}  ARCE.AI-v0.1.1.apk\n"))
    }
}
