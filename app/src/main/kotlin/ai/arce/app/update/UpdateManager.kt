package ai.arce.app.update

import ai.arce.app.BuildConfig
import ai.arce.app.ArceApp
import ai.arce.app.system.Notifications
import ai.arce.core.update.Release
import ai.arce.core.update.ReleaseAsset
import ai.arce.core.update.ReleaseParser
import ai.arce.core.update.Version
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.provider.Settings
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.io.File
import java.net.HttpURLConnection
import java.net.URI
import java.security.MessageDigest
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext

sealed interface UpdateState {
    data object Idle : UpdateState
    data object Checking : UpdateState
    data object UpToDate : UpdateState
    data class Available(val release: Release) : UpdateState
    data class Downloading(val release: Release, val done: Long, val total: Long) : UpdateState
    data class ReadyToInstall(val release: Release, val apk: File) : UpdateState
    data class Failed(val reason: String) : UpdateState
}

/**
 * Updates from the private GitHub repository (決定事項9): check periodically, notify, and
 * download only after the user approves; verify the published SHA-256; install with
 * PackageInstaller. The APK must be signed with the same key as the installed app.
 */
class UpdateManager(private val context: Context) {
    val currentVersion: Version? = Version.parse(BuildConfig.VERSION_NAME)

    private fun token(): String? = (context.applicationContext as ArceApp).container.secrets.get(TOKEN_NAME)

    suspend fun latest(repo: String): Release = withContext(Dispatchers.IO) {
        val body = get("https://api.github.com/repos/$repo/releases/latest", "application/vnd.github+json")
        ReleaseParser.parse(body) ?: error("latest release has no version tag")
    }

    fun isNewer(release: Release): Boolean = currentVersion == null || release.version > currentVersion

    /** Downloads the APK asset and checks it against the release's .sha256 asset. */
    suspend fun download(repo: String, release: Release, onProgress: (Long, Long) -> Unit): File = withContext(Dispatchers.IO) {
        val apkAsset = release.apk ?: error("release ${release.tag} has no APK")
        val expected = release.checksum?.let { ReleaseParser.parseChecksum(assetText(repo, it)) }
            ?: error("release ${release.tag} has no .sha256 file")
        val dir = File(context.cacheDir, "updates").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, apkAsset.name)
        val digest = MessageDigest.getInstance("SHA-256")
        openAsset(repo, apkAsset).inputStream.use { input ->
            file.outputStream().use { output ->
                val buffer = ByteArray(1 shl 16)
                var done = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    output.write(buffer, 0, n)
                    digest.update(buffer, 0, n)
                    done += n
                    onProgress(done, apkAsset.sizeBytes)
                }
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (!actual.equals(expected, ignoreCase = true)) {
            file.delete()
            error("SHA-256 mismatch; the download was discarded")
        }
        file
    }

    fun canInstall(): Boolean = context.packageManager.canRequestPackageInstalls()

    /** Opens the system screen where the user allows ARCE.AI to install apps (first time only). */
    fun installPermissionIntent(): Intent =
        Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    fun install(apk: File) {
        val installer = context.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(context.packageName)
            // Android 12+: no second confirmation when ARCE.AI installed the current version itself.
            setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            session.openWrite("base.apk", 0, apk.length()).use { out ->
                apk.inputStream().use { it.copyTo(out) }
                session.fsync(out)
            }
            val callback = PendingIntent.getBroadcast(
                context, sessionId, Intent(context, InstallResultReceiver::class.java),
                PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            session.commit(callback.intentSender)
        }
    }

    private fun assetText(repo: String, asset: ReleaseAsset): String =
        openAsset(repo, asset).inputStream.bufferedReader().use { it.readText() }

    /**
     * Asset downloads answer with a redirect to signed storage. The GitHub token must not be
     * sent there (the storage rejects a second credential), so the redirect is followed by hand.
     */
    private fun openAsset(repo: String, asset: ReleaseAsset): HttpURLConnection {
        val api = connection("https://api.github.com/repos/$repo/releases/assets/${asset.id}", "application/octet-stream", withToken = true)
        api.instanceFollowRedirects = false
        val code = api.responseCode
        if (code in 300..399) {
            val location = api.getHeaderField("Location") ?: error("redirect without location")
            api.disconnect()
            val storage = connection(location, "application/octet-stream", withToken = false)
            check(storage.responseCode in 200..299) { "asset download failed: HTTP ${storage.responseCode}" }
            return storage
        }
        check(code in 200..299) { "asset download failed: HTTP $code" }
        return api
    }

    private fun get(url: String, accept: String): String {
        val c = connection(url, accept, withToken = true)
        try {
            when (val code = c.responseCode) {
                in 200..299 -> return c.inputStream.bufferedReader().use { it.readText() }
                401, 403 -> error("GitHub rejected the token (HTTP $code). Check the token in Settings.")
                404 -> error("No release found (HTTP 404). For a private repository a token with Contents: read is required.")
                else -> error("GitHub HTTP $code")
            }
        } finally {
            c.disconnect()
        }
    }

    private fun connection(url: String, accept: String, withToken: Boolean): HttpURLConnection {
        val c = URI(url).toURL().openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        c.setRequestProperty("Accept", accept)
        c.setRequestProperty("User-Agent", "ARCE.AI/${BuildConfig.VERSION_NAME}")
        c.setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        if (withToken) token()?.let { c.setRequestProperty("Authorization", "Bearer $it") }
        return c
    }

    companion object {
        const val TOKEN_NAME = "github_token"
        private const val WORK_NAME = "update-check"

        fun schedule(context: Context, intervalHours: Int, wifiOnly: Boolean) {
            val request = PeriodicWorkRequestBuilder<UpdateCheckWorker>(intervalHours.toLong().coerceAtLeast(1), TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
                        .build(),
                )
                .build()
            WorkManager.getInstance(context).enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }
}

/** Periodic check; only notifies. Downloading waits for the user's approval in the app. */
class UpdateCheckWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val container = (applicationContext as ArceApp).container
        val settings = container.settingsRepository.settings.first()
        return try {
            val release = container.updates.latest(settings.updateRepo)
            if (container.updates.isNewer(release)) {
                Notifications.post(
                    applicationContext, Notifications.ID_UPDATE, Notifications.CHANNEL_UPDATES,
                    "ARCE.AI ${release.tag} があります", "タップして更新内容を確認", screen = "update",
                )
            }
            Result.success()
        } catch (e: Exception) {
            Result.retry()
        }
    }
}

/** Receives PackageInstaller results (updates and built apps); asks the system to show its confirmation when needed. */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT) ?: return
                context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            }
            PackageInstaller.STATUS_SUCCESS -> Unit
            else -> Notifications.post(
                context, Notifications.ID_UPDATE, Notifications.CHANNEL_UPDATES, "インストールに失敗しました",
                intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "不明なエラー",
            )
        }
    }
}
