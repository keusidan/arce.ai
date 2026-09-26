package ai.arce.core.toolchain

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Writes AndroidManifest.xml in Android's compiled binary XML format (the job aapt2 does when
 * it links an app), so a small app can be packaged on the phone without an aapt2 binary.
 *
 * Only what a code-only app needs is supported: elements, the android namespace, and string,
 * integer and boolean attributes. Apps built this way carry no resources (layouts, images);
 * labels are plain strings and the system default icon is used.
 */
class BinaryManifest private constructor(private val root: Element) {

    class Attr internal constructor(val android: Boolean, val name: String, val value: Any)

    class Element(val name: String) {
        internal val attrs = mutableListOf<Attr>()
        internal val children = mutableListOf<Element>()

        fun attr(name: String, value: String) = apply { attrs += Attr(false, name, value) }
        fun android(name: String, value: Any) = apply {
            require(name in ANDROID_ATTRS) { "unknown android attribute: $name" }
            require(value is String || value is Int || value is Boolean) { "unsupported value for $name" }
            attrs += Attr(true, name, value)
        }
        fun child(name: String, block: Element.() -> Unit = {}) = apply { children += Element(name).apply(block) }
    }

    fun toByteArray(): ByteArray {
        // Attribute names that map to framework resource ids come first in the string pool,
        // in the same order as the resource map (that is how the parser resolves them).
        val all = mutableListOf<Element>().also { collect(root, it) }
        val androidNames = all.flatMap { e -> e.attrs.filter { it.android }.map { it.name } }.distinct()
            .sortedBy { ANDROID_ATTRS.getValue(it) }
        val strings = LinkedHashSet<String>(androidNames)
        strings += ANDROID_PREFIX
        strings += ANDROID_NS
        all.forEach { e ->
            strings += e.name
            e.attrs.forEach { a ->
                strings += a.name
                if (a.value is String) strings += a.value
            }
        }
        val pool = strings.toList()
        val index = pool.withIndex().associate { (i, s) -> s to i }

        val body = ByteArrayOutputStream()
        body.write(stringPool(pool))
        body.write(resourceMap(androidNames.map { ANDROID_ATTRS.getValue(it) }))
        body.write(namespace(START_NAMESPACE, index.getValue(ANDROID_PREFIX), index.getValue(ANDROID_NS)))
        writeElement(root, index, body)
        body.write(namespace(END_NAMESPACE, index.getValue(ANDROID_PREFIX), index.getValue(ANDROID_NS)))

        val bytes = body.toByteArray()
        return le(8 + bytes.size).apply {
            putShort(XML.toShort()); putShort(8); putInt(8 + bytes.size); put(bytes)
        }.array()
    }

    private fun collect(e: Element, into: MutableList<Element>) {
        into += e
        e.children.forEach { collect(it, into) }
    }

    private fun writeElement(e: Element, index: Map<String, Int>, out: ByteArrayOutputStream) {
        val nsIndex = index.getValue(ANDROID_NS)
        // The framework looks attributes up by resource id; keep them sorted like aapt2 does.
        val attrs = e.attrs.sortedWith(compareBy({ if (it.android) 0 else 1 }, { ANDROID_ATTRS[it.name] ?: 0 }, { it.name }))
        val size = 16 + 20 + attrs.size * 20
        out.write(le(size).apply {
            putShort(START_ELEMENT.toShort()); putShort(16); putInt(size)
            putInt(1); putInt(-1)                        // line number, no comment
            putInt(-1); putInt(index.getValue(e.name))   // no namespace, element name
            putShort(20); putShort(20); putShort(attrs.size.toShort())
            putShort(0); putShort(0); putShort(0)         // id, class, style attribute indexes
            attrs.forEach { a ->
                putInt(if (a.android) nsIndex else -1)
                putInt(index.getValue(a.name))
                when (val v = a.value) {
                    is String -> { putInt(index.getValue(v)); typed(TYPE_STRING, index.getValue(v)) }
                    is Int -> { putInt(-1); typed(TYPE_INT_DEC, v) }
                    is Boolean -> { putInt(-1); typed(TYPE_INT_BOOLEAN, if (v) -1 else 0) }
                }
            }
        }.array())
        e.children.forEach { writeElement(it, index, out) }
        out.write(le(24).apply {
            putShort(END_ELEMENT.toShort()); putShort(16); putInt(24)
            putInt(1); putInt(-1); putInt(-1); putInt(index.getValue(e.name))
        }.array())
    }

    private fun ByteBuffer.typed(type: Int, data: Int) {
        putShort(8); put(0); put(type.toByte()); putInt(data)
    }

    companion object {
        const val ANDROID_NS = "http://schemas.android.com/apk/res/android"
        private const val ANDROID_PREFIX = "android"

        private const val STRING_POOL = 0x0001
        private const val XML = 0x0003
        private const val START_NAMESPACE = 0x0100
        private const val END_NAMESPACE = 0x0101
        private const val START_ELEMENT = 0x0102
        private const val END_ELEMENT = 0x0103
        private const val RESOURCE_MAP = 0x0180
        private const val TYPE_STRING = 0x03
        private const val TYPE_INT_DEC = 0x10
        private const val TYPE_INT_BOOLEAN = 0x12

        /** Framework attribute ids (android.R.attr) of the attributes this writer supports. */
        val ANDROID_ATTRS: Map<String, Int> = mapOf(
            "label" to 0x01010001,
            "icon" to 0x01010002,
            "name" to 0x01010003,
            "debuggable" to 0x0101000f,
            "exported" to 0x01010010,
            "minSdkVersion" to 0x0101020c,
            "versionCode" to 0x0101021b,
            "versionName" to 0x0101021c,
            "targetSdkVersion" to 0x01010270,
        )

        fun build(rootName: String, block: Element.() -> Unit) = BinaryManifest(Element(rootName).apply(block))

        /** A launcher app with one Activity, as the APK builder produces it. */
        fun launcherApp(packageName: String, label: String, activityClass: String, minSdk: Int, targetSdk: Int,
                        versionCode: Int = 1, versionName: String = "1.0") =
            build("manifest") {
                attr("package", packageName)
                android("versionCode", versionCode)
                android("versionName", versionName)
                child("uses-sdk") {
                    android("minSdkVersion", minSdk)
                    android("targetSdkVersion", targetSdk)
                }
                child("application") {
                    android("label", label)
                    child("activity") {
                        android("name", activityClass)
                        android("label", label)
                        android("exported", true)
                        child("intent-filter") {
                            child("action") { android("name", "android.intent.action.MAIN") }
                            child("category") { android("name", "android.intent.category.LAUNCHER") }
                        }
                    }
                }
            }

        private fun le(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)

        /** UTF-16 string pool: each entry is a length, the characters, and a 0 terminator. */
        private fun stringPool(strings: List<String>): ByteArray {
            val data = ByteArrayOutputStream()
            val offsets = strings.map { s ->
                val offset = data.size()
                require(s.length < 0x8000) { "string too long" }
                data.write(le(2 + s.length * 2 + 2).apply {
                    putShort(s.length.toShort()); s.forEach { putChar(it) }; putShort(0)
                }.array())
                offset
            }
            while (data.size() % 4 != 0) data.write(0)
            val header = 28
            val stringsStart = header + strings.size * 4
            val size = stringsStart + data.size()
            return le(size).apply {
                putShort(STRING_POOL.toShort()); putShort(header.toShort()); putInt(size)
                putInt(strings.size); putInt(0); putInt(0)  // no styles, UTF-16
                putInt(stringsStart); putInt(0)
                offsets.forEach { putInt(it) }
                put(data.toByteArray())
            }.array()
        }

        private fun resourceMap(ids: List<Int>): ByteArray {
            val size = 8 + ids.size * 4
            return le(size).apply {
                putShort(RESOURCE_MAP.toShort()); putShort(8); putInt(size); ids.forEach { putInt(it) }
            }.array()
        }

        private fun namespace(type: Int, prefix: Int, uri: Int): ByteArray = le(24).apply {
            putShort(type.toShort()); putShort(16); putInt(24); putInt(1); putInt(-1); putInt(prefix); putInt(uri)
        }.array()
    }
}
