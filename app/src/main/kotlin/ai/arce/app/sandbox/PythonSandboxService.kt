package ai.arce.app.sandbox

import android.os.Bundle
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform

/**
 * Runs Python (Chaquopy) in the separate ":python" process. Chaquopy needs the app's files
 * directory for its standard library, so unlike the Java runner this process cannot be an
 * isolated one: the code runs with ARCE.AI's permissions (network, the app's own files).
 * The consent window says so before anything runs.
 */
class PythonSandboxService : SandboxService() {
    override fun execute(data: Bundle): Pair<Boolean, String> {
        val code = requireNotNull(data.getString(KEY_CODE)) { "no code" }
        if (!Python.isStarted()) Python.start(AndroidPlatform(this))
        val result = Python.getInstance().getModule("arce_runner").callAttr("run", code).asList()
        return result[0].toBoolean() to result[1].toString()
    }

    companion object {
        const val KEY_CODE = "code"
    }
}
