package ai.arce.app.toolchain

import ai.arce.core.toolchain.BinaryManifest
import ai.arce.core.toolchain.JavaSource
import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import com.android.apksig.ApkSigner
import com.android.tools.r8.CompilationMode
import com.android.tools.r8.D8
import com.android.tools.r8.D8Command
import com.android.tools.r8.OutputMode
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.cert.X509Certificate
import java.util.Date
import java.util.jar.Attributes
import java.util.jar.JarEntry
import java.util.jar.JarOutputStream
import java.util.jar.Manifest
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.security.auth.x500.X500Principal
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.eclipse.jdt.internal.compiler.batch.Main as Ecj

class BuildException(message: String) : Exception(message)

/** Compiled classes of one source file. */
class Compiled(val source: JavaSource, val classesDir: File, val log: String)

/**
 * The Termux-free build chain (決定事項2): ECJ compiles Java to class files, D8 turns them into
 * dex, and apksig signs APKs. aapt2 is replaced by [BinaryManifest], so generated apps carry
 * code only (no layouts or images; UIs are built in code).
 *
 * Java language level is 8 (lambdas, generics; no `var`): newer levels make ECJ look for a
 * JDK module image, which Android does not have.
 */
class JavaToolchain(private val context: Context) {
    private val root = File(context.cacheDir, "javabuild")
    private val outputs = File(context.getExternalFilesDir(null), "builds").apply { mkdirs() }
    private val lock = Mutex()

    /** The SDK's android.jar, copied out of the APK's assets once per app version. */
    private val androidJar: File by lazy {
        val target = File(context.noBackupFilesDir, "toolchain/android-${versionCode()}.jar")
        if (!target.exists()) {
            target.parentFile?.listFiles()?.forEach { it.delete() }
            target.parentFile?.mkdirs()
            val temp = File(target.path + ".part")
            context.assets.open("android.jar").use { input -> temp.outputStream().use { input.copyTo(it) } }
            check(temp.renameTo(target))
        }
        target
    }

    @Suppress("DEPRECATION")
    private fun versionCode(): Long = context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode

    suspend fun compile(source: JavaSource): Compiled = lock.withLock {
        withContext(Dispatchers.IO) {
            val work = File(root, "job-${System.nanoTime()}").apply { deleteRecursively(); mkdirs() }
            val srcFile = File(work, "src/${source.fileName}").apply { parentFile?.mkdirs(); writeText(source.code) }
            val classes = File(work, "classes").apply { mkdirs() }
            val log = StringWriter()
            val writer = PrintWriter(log)
            val ok = Ecj(writer, writer, false, null, null).compile(
                arrayOf(
                    "-${JavaSource.JAVA_LEVEL}", "-proc:none", "-nowarn", "-encoding", "UTF-8",
                    "-bootclasspath", androidJar.absolutePath, "-d", classes.absolutePath, srcFile.absolutePath,
                ),
            )
            writer.flush()
            if (!ok) throw BuildException(log.toString().replace(work.absolutePath + "/", "").ifBlank { "コンパイルに失敗しました" })
            Compiled(source, classes, log.toString())
        }
    }

    /** classes.dex for the compiled classes (minimum API = this app's). */
    suspend fun dex(compiled: Compiled): ByteArray = withContext(Dispatchers.IO) {
        val out = File(compiled.classesDir.parentFile, "dex").apply { deleteRecursively(); mkdirs() }
        val classFiles = compiled.classesDir.walkTopDown().filter { it.isFile && it.extension == "class" }.map { it.toPath() }.toList()
        D8.run(
            D8Command.builder()
                .addProgramFiles(classFiles)
                .addLibraryFiles(androidJar.toPath())
                .setMinApiLevel(MIN_SDK)
                .setMode(CompilationMode.RELEASE)
                .setOutput(out.toPath(), OutputMode.DexIndexed)
                .build(),
        )
        File(out, "classes.dex").readBytes()
    }

    /** A runnable JAR (class files, Main-Class set) for a desktop JVM. */
    suspend fun jar(compiled: Compiled): File = withContext(Dispatchers.IO) {
        val main = compiled.source.mainClass ?: throw BuildException("main メソッドがないためJARを作れません")
        val file = File(outputs, "${compiled.source.primaryClass}.jar")
        val manifest = Manifest().apply {
            mainAttributes[Attributes.Name.MANIFEST_VERSION] = "1.0"
            mainAttributes[Attributes.Name.MAIN_CLASS] = main
            mainAttributes[Attributes.Name("Created-By")] = "ARCE.AI"
        }
        JarOutputStream(file.outputStream(), manifest).use { jar ->
            compiled.classesDir.walkTopDown().filter { it.isFile }.forEach { f ->
                jar.putNextEntry(JarEntry(f.relativeTo(compiled.classesDir).invariantSeparatorsPath))
                f.inputStream().use { it.copyTo(jar) }
                jar.closeEntry()
            }
        }
        file
    }

    /**
     * Builds and signs an installable APK from a source file with an Activity. The APK is
     * signed with ARCE.AI's own key in the Android Keystore, so rebuilt versions of the same
     * app can be installed over each other.
     */
    suspend fun apk(original: JavaSource): File {
        val source = original.withPackage(DEFAULT_PACKAGE)
        val activity = source.activityClass ?: throw BuildException("android.app.Activity を継承したクラスがないためAPKを作れません")
        val packageName = requireNotNull(source.packageName)
        val dex = dex(compile(source))
        return withContext(Dispatchers.IO) {
            val label = activity.substringAfterLast('.')
            val unsigned = File(root, "$label-unsigned.apk")
            ZipOutputStream(unsigned.outputStream()).use { zip ->
                zip.putNextEntry(ZipEntry("AndroidManifest.xml"))
                zip.write(BinaryManifest.launcherApp(packageName, label, activity, MIN_SDK, TARGET_SDK).toByteArray())
                zip.closeEntry()
                zip.putNextEntry(ZipEntry("classes.dex"))
                zip.write(dex)
                zip.closeEntry()
            }
            val signed = File(outputs, "$label.apk")
            val (key, cert) = signingKey()
            ApkSigner.Builder(listOf(ApkSigner.SignerConfig.Builder("ARCE", key, listOf(cert)).build()))
                .setInputApk(unsigned)
                .setOutputApk(signed)
                .setMinSdkVersion(MIN_SDK)
                .setV1SigningEnabled(false)
                .setV2SigningEnabled(true)
                .setV3SigningEnabled(true)
                .build()
                .sign()
            unsigned.delete()
            signed
        }
    }

    /** RSA key that never leaves the Android Keystore; its self-signed certificate is created with it. */
    private fun signingKey(): Pair<java.security.PrivateKey, X509Certificate> {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (!store.containsAlias(KEY_ALIAS)) {
            val now = System.currentTimeMillis()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply {
                initialize(
                    KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
                        .setKeySize(2048)
                        .setDigests(KeyProperties.DIGEST_SHA256, KeyProperties.DIGEST_SHA512)
                        .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PKCS1)
                        .setCertificateSubject(X500Principal("CN=ARCE.AI generated apps"))
                        .setCertificateSerialNumber(java.math.BigInteger.valueOf(now))
                        .setCertificateNotBefore(Date(now - 86_400_000L))
                        .setCertificateNotAfter(Date(now + 30L * 365 * 86_400_000L))
                        .build(),
                )
            }.generateKeyPair()
        }
        val entry = store.getEntry(KEY_ALIAS, null) as KeyStore.PrivateKeyEntry
        return entry.privateKey to (entry.certificate as X509Certificate)
    }

    companion object {
        const val MIN_SDK = 31
        const val TARGET_SDK = 36
        const val DEFAULT_PACKAGE = "ai.arce.generated"
        private const val KEY_ALIAS = "arce-generated-apps"
    }
}
