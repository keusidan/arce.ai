package ai.arce.app.system

import ai.arce.app.data.ConsentDao
import ai.arce.app.data.ConsentEntity
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** What is being asked for, shown in the consent window. */
data class ConsentRequest(
    val scope: String,
    val title: String,
    /** e.g. the code to run, or which data will be read */
    val detail: String,
    val permissions: List<String>,
    internal val answer: CompletableDeferred<ConsentAnswer> = CompletableDeferred(),
)

enum class ConsentAnswer { DENY, ONCE, ALWAYS }

/**
 * The app's own permission window (決定事項4). Android has no system permission for an app's
 * private data, so ARCE.AI asks before generated code runs or app data leaves the app, and
 * remembers "always" answers in Room; they can be revoked in Settings.
 */
class ConsentManager(private val dao: ConsentDao) {
    private val _pending = MutableStateFlow<ConsentRequest?>(null)
    val pending: StateFlow<ConsentRequest?> = _pending.asStateFlow()

    val granted = dao.observeAll()

    suspend fun request(scope: String, title: String, detail: String, permissions: List<String>): Boolean {
        if (dao.get(scope)?.always == true) return true
        val request = ConsentRequest(scope, title, detail, permissions)
        _pending.value = request
        val answer = request.answer.await()
        _pending.value = null
        if (answer == ConsentAnswer.ALWAYS) dao.upsert(ConsentEntity(scope, System.currentTimeMillis(), always = true))
        return answer != ConsentAnswer.DENY
    }

    fun respond(answer: ConsentAnswer) {
        _pending.value?.answer?.complete(answer)
    }

    suspend fun revoke(scope: String) = dao.revoke(scope)

    companion object {
        const val SCOPE_RUN_CODE = "code.run"
        const val SCOPE_EXPORT_HISTORY = "history.export"
    }
}
