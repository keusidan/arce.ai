package ai.arce.app

import ai.arce.app.bridge.EngineBridge
import ai.arce.app.bridge.SystemBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var engineBridge: EngineBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        engineBridge = EngineBridge(applicationContext, messenger)
        SystemBridge(applicationContext, messenger)
    }

    override fun onDestroy() {
        // keep the model loaded across a configuration change; free it only when the app is really closing
        if (isFinishing) engineBridge?.close()
        super.onDestroy()
    }
}
