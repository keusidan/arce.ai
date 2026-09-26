package ai.arce.app

import ai.arce.app.engine.LlamaCppEngine
import ai.arce.app.model.ModelStore
import ai.arce.core.chat.ChatController
import ai.arce.core.engine.LoadParams
import android.app.Application
import android.net.Uri
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking

data class ModelUiState(
    val available: List<File> = emptyList(),
    val loaded: String? = null,
    /** Non-null while loading or importing, e.g. "読み込み中…". */
    val busy: String? = null,
    val error: String? = null,
)

class ChatViewModel(application: Application) : AndroidViewModel(application) {
    private val engine = LlamaCppEngine()
    private val store = ModelStore(application)

    val chat = ChatController(engine, viewModelScope)

    private val _model = MutableStateFlow(ModelUiState(available = store.list()))
    val model: StateFlow<ModelUiState> = _model.asStateFlow()

    fun loadModel(file: File) {
        viewModelScope.launch {
            _model.update { it.copy(busy = "${file.name} を読み込み中…", error = null) }
            try {
                engine.load(LoadParams(path = file.absolutePath, threads = defaultThreads()))
                _model.update { it.copy(loaded = file.nameWithoutExtension, busy = null) }
            } catch (e: Exception) {
                _model.update { it.copy(loaded = null, busy = null, error = e.message) }
            }
        }
    }

    fun importModel(uri: Uri) {
        viewModelScope.launch {
            try {
                val file = store.import(uri) { copied ->
                    _model.update { it.copy(busy = "コピー中… ${copied / 1_000_000} MB") }
                }
                _model.update { it.copy(available = store.list(), busy = null) }
                loadModel(file)
            } catch (e: Exception) {
                _model.update { it.copy(busy = null, error = e.message) }
            }
        }
    }

    override fun onCleared() {
        runBlocking { engine.unload() }
    }

    // Half the cores: phones mix fast and slow cores, and llama.cpp waits for the slowest thread.
    private fun defaultThreads() = (Runtime.getRuntime().availableProcessors() / 2).coerceIn(2, 6)
}
