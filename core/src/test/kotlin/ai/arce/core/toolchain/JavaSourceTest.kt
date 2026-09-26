package ai.arce.core.toolchain

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class JavaSourceTest {
    @Test
    fun `finds file name and main class`() {
        val src = JavaSource.parse(
            """
            import java.util.*;
            class Helper { }
            public class Hello {
                public static void main(String[] args) { System.out.println("class Fake"); }
            }
            """.trimIndent(),
        )
        assertEquals("Hello.java", src.fileName)
        assertEquals("Hello", src.mainClass)
        assertNull(src.activityClass)
    }

    @Test
    fun `qualifies names with the package and finds the activity`() {
        val src = JavaSource.parse(
            """
            package com.example.app;
            // public class Commented extends Activity {}
            import android.app.Activity;
            public class MainActivity extends Activity { }
            """.trimIndent(),
        )
        assertEquals("com.example.app.MainActivity", src.activityClass)
        assertNull(src.mainClass)
    }

    @Test
    fun `adds a package only when missing`() {
        val src = JavaSource.parse("public class A extends android.app.Activity {}").withPackage("ai.arce.generated")
        assertEquals("ai.arce.generated", src.packageName)
        assertEquals("ai.arce.generated.A", src.activityClass)
        assertEquals("p", JavaSource.parse("package p; class B {}").withPackage("x").packageName)
    }

    @Test
    fun `varargs main and missing classes`() {
        assertEquals("C", JavaSource.parse("class C { public static void main(String... a) {} }").mainClass)
        assertThrows<IllegalArgumentException> { JavaSource.parse("int x = 1;") }
    }
}
