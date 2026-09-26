package ai.arce.app.sandbox

import android.os.Bundle
import dalvik.system.InMemoryDexClassLoader
import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.io.PrintStream
import java.lang.reflect.InvocationTargetException
import java.nio.ByteBuffer

/**
 * Runs a compiled Java program (dex bytes) in an isolated process: it has its own throw-away
 * UID, no permissions, no network and no access to ARCE.AI's files (android:isolatedProcess).
 */
class JavaSandboxService : SandboxService() {
    override fun execute(data: Bundle): Pair<Boolean, String> {
        val dex = requireNotNull(data.getByteArray(KEY_DEX)) { "no dex" }
        val mainClass = requireNotNull(data.getString(KEY_MAIN)) { "no main class" }

        val buffer = LimitedBuffer(MAX_OUTPUT)
        val stream = PrintStream(buffer, true, "UTF-8")
        System.setOut(stream)
        System.setErr(stream)
        // Only the framework is visible to the program, not ARCE.AI's own classes.
        val loader = InMemoryDexClassLoader(ByteBuffer.wrap(dex), ClassLoader.getSystemClassLoader())
        return try {
            loader.loadClass(mainClass).getMethod("main", Array<String>::class.java).invoke(null, arrayOf<String>())
            stream.flush()
            true to buffer.text()
        } catch (e: InvocationTargetException) {
            e.targetException.printStackTrace(stream)
            stream.flush()
            false to buffer.text()
        }
    }

    /** Keeps the first [limit] bytes; a program printing forever cannot exhaust memory. */
    private class LimitedBuffer(private val limit: Int) : OutputStream() {
        private val bytes = ByteArrayOutputStream()
        private var dropped = false
        override fun write(b: Int) {
            if (bytes.size() < limit) bytes.write(b) else dropped = true
        }
        override fun write(b: ByteArray, off: Int, len: Int) {
            val room = limit - bytes.size()
            if (room > 0) bytes.write(b, off, minOf(room, len))
            if (len > room) dropped = true
        }
        fun text() = bytes.toString("UTF-8") + if (dropped) "\n… (出力が長いため省略)" else ""
    }

    companion object {
        const val KEY_DEX = "dex"
        const val KEY_MAIN = "main"
    }
}
