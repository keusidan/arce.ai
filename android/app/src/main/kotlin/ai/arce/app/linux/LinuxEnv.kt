package ai.arce.app.linux

import java.io.File
import java.io.IOException
import java.security.MessageDigest

/**
 * The Linux environment of the app: an Ubuntu root file system (downloaded once) that proot runs
 * commands in, and one **workspace folder shared by every chat**, seen inside as `/workspace`, whose
 * size is limited. It knows folders and command lines only (no Android classes), so it runs on a
 * plain JVM too; [ai.arce.app.bridge.SystemBridge] hands it the app's folders.
 *
 * proot is not a sandbox: a command runs with the app's own user, and proot only translates paths.
 * What stands between a model and the device is the approval card the app shows for every command
 * (a setting), the workspace limit, the time limit and the output limit.
 */
class LinuxEnv(
    private val prootLibraryDir: File,
    private val baseDir: File,
    private val tmpDir: File,
) {
    val rootfs = File(baseDir, "linux/rootfs")
    private val partial = File(baseDir, "linux/rootfs.partial")
    private val marker = File(baseDir, "linux/rootfs.json")
    val workspace = File(baseDir, "workspace")
    private val prootTmp = File(tmpDir, "proot-tmp")

    private val proot get() = File(prootLibraryDir, "libproot.so")
    private val loader get() = File(prootLibraryDir, "libproot_loader.so")

    private val lock = Any()

    fun installed(): Boolean = rootfs.isDirectory && marker.isFile && File(rootfs, "bin").exists()

    fun status(limitBytes: Long): Map<String, Any?> {
        val usage = DiskUsage.sizeOf(workspace)
        return mapOf(
            "prootPresent" to (proot.isFile && loader.isFile),
            "installed" to installed(),
            "rootfs" to (if (marker.isFile) marker.readText() else null),
            "workspaceBytes" to usage,
            "workspaceLimitBytes" to limitBytes,
        )
    }

    /**
     * Checks [archive] against [sha256] (when given), unpacks it, and finishes it for proot. Nothing is in
     * place until all of it worked: it is unpacked beside the final folder and moved.
     */
    fun install(archive: File, sha256: String?, dnsServers: List<String>, maxBytes: Long, onProgress: ((Long) -> Unit)? = null): Map<String, Any?> {
        synchronized(lock) {
            val actual = sha256Of(archive)
            if (sha256 != null && sha256.isNotBlank() && !actual.equals(sha256.trim(), ignoreCase = true)) {
                throw IOException("the SHA-256 of the file is $actual, not the one in the settings")
            }
            DiskUsage.delete(partial)
            try {
                // 0 (or less) is "no limit": what Ubuntu Base ships is the system, not the work
                val result = TarGz.extract(archive, partial, if (maxBytes <= 0) Long.MAX_VALUE else maxBytes, onProgress)
                finish(partial, dnsServers)
                DiskUsage.delete(rootfs)
                rootfs.parentFile?.mkdirs()
                if (!partial.renameTo(rootfs)) throw IOException("could not move the unpacked folder into place")
                marker.writeText(
                    """{"archive":"${archive.name}","sha256":"$actual","files":${result.files},"bytes":${result.bytes},"at":${System.currentTimeMillis()}}""",
                )
                workspaceHome().mkdirs()
                return mapOf("files" to result.files, "bytes" to result.bytes, "skipped" to result.skipped)
            } catch (e: Throwable) {
                DiskUsage.delete(partial)
                throw e
            }
        }
    }

    fun remove() {
        synchronized(lock) {
            DiskUsage.delete(rootfs)
            DiskUsage.delete(partial)
            marker.delete()
        }
    }

    /** Empties the shared workspace (the folder stays). */
    fun clearWorkspace() {
        synchronized(lock) {
            DiskUsage.clear(workspace)
            workspaceHome().mkdirs()
        }
    }

    private fun workspaceHome() = File(workspace, "home")

    /** What proot needs inside the root file system, besides what Ubuntu ships. */
    internal fun finish(dir: File, dnsServers: List<String>) {
        val etc = File(dir, "etc").apply { mkdirs() }
        // a link to the host's resolver (systemd) would point at nothing: a plain file
        File(etc, "resolv.conf").let { DiskUsage.delete(it); it.writeText(dnsServers.filter { s -> s.isNotBlank() }.joinToString("") { s -> "nameserver ${s.trim()}\n" }) }
        File(etc, "hosts").writeText("127.0.0.1 localhost\n::1 localhost ip6-localhost ip6-loopback\n")
        File(etc, "hostname").writeText("arce\n")
        // apt tries to drop to its own user for downloads, which a proot without real users cannot do
        // (APT::Sandbox::User: https://manpages.ubuntu.com/manpages/noble/man5/apt.conf.5.html)
        File(etc, "apt/apt.conf.d").mkdirs()
        File(etc, "apt/apt.conf.d/99arce").writeText("APT::Sandbox::User \"root\";\n")
        File(dir, "workspace").mkdirs()
        File(dir, "tmp").apply { mkdirs(); setWritable(true, false); setReadable(true, false); setExecutable(true, false) }
    }

    /** The proot command line for [command] (an `sh -c` string), run in [cwd] inside the root file system. */
    internal fun prootCommand(command: String, cwd: String): List<String> = listOf(
        proot.path,
        "--kill-on-exit",
        "--link2symlink",
        "-0",
        "-r", rootfs.path,
        "-b", "/dev",
        "-b", "/proc",
        "-b", "${workspace.path}:/workspace",
        "-w", cwd,
        "/usr/bin/env", "-i",
        "HOME=/workspace/home",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG=C.UTF-8",
        "TERM=dumb",
        "TMPDIR=/tmp",
        "SHELL=/bin/bash",
        "/bin/bash", "-c", command,
    )

    class RunParams(
        val command: String,
        val cwd: String,
        val timeoutSeconds: Int,
        val maxOutputChars: Int,
        val workspaceLimitBytes: Long,
        /** Starts proot without its seccomp filter (some devices refuse it). */
        val noSeccomp: Boolean,
        val watchEveryMs: Long = 2000,
    )

    /** One command at a time: the workspace is shared, and a phone has few cores. */
    fun run(params: RunParams): Map<String, Any?> {
        if (!installed()) throw IOException("the Linux environment is not installed")
        if (!proot.isFile || !loader.isFile) throw IOException("this app has no proot")
        require(params.cwd.startsWith("/") && !params.cwd.contains('\n') && !params.cwd.contains('\u0000')) { "cwd must be an absolute path" }
        require(!params.command.contains('\u0000')) { "the command has a NUL character" }
        synchronized(lock) {
            workspace.mkdirs()
            workspaceHome().mkdirs()
            prootTmp.mkdirs()
            val env = mutableMapOf("PROOT_LOADER" to loader.path, "PROOT_TMP_DIR" to prootTmp.path)
            if (params.noSeccomp) env["PROOT_NO_SECCOMP"] = "1"
            val before = DiskUsage.sizeOf(workspace)
            val limit = params.workspaceLimitBytes
            val result = ShellRunner().run(
                ShellRunner.Request(
                    command = prootCommand(params.command, params.cwd),
                    env = env,
                    timeoutMs = params.timeoutSeconds * 1000L,
                    maxOutputBytes = params.maxOutputChars * 3,
                    watchEveryMs = params.watchEveryMs,
                    // a command that starts over the limit may still delete things; one that grows past it is stopped
                    watch = {
                        if (limit <= 0) null else {
                            val now = DiskUsage.sizeOf(workspace, limit + 1)
                            if (now > limit && now > before) "workspace" else null
                        }
                    },
                ),
            )
            val after = DiskUsage.sizeOf(workspace)
            return mapOf(
                "exit" to result.exit,
                "stdout" to result.stdout,
                "stderr" to result.stderr,
                "truncated" to result.truncated,
                "killedBy" to result.killedBy,
                "elapsedMs" to result.elapsedMs,
                "workspaceBytes" to after,
                "workspaceLimitBytes" to limit,
            )
        }
    }

    companion object {
        fun sha256Of(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            file.inputStream().buffered(1 shl 16).use { input ->
                val buffer = ByteArray(1 shl 16)
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    digest.update(buffer, 0, n)
                }
            }
            return digest.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
