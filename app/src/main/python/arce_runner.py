"""Runs a Python snippet from a chat code block and returns what it printed.

Called from ai.arce.app.sandbox.PythonSandboxService, which runs in its own process
(":python") and kills that process when the time limit is reached.
"""
import contextlib
import io
import traceback

MAX_OUTPUT = 64 * 1024


def run(code):
    out = io.StringIO()
    ok = True
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
        try:
            exec(compile(code, "<code block>", "exec"), {"__name__": "__main__"})
        except SystemExit:
            pass
        except BaseException:
            ok = False
            traceback.print_exc()
    text = out.getvalue()
    if len(text) > MAX_OUTPUT:
        text = text[:MAX_OUTPUT] + "\n… (出力が長いため省略)"
    return [ok, text]
