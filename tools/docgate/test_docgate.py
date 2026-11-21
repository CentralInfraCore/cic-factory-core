"""Regression tests of the documentation gate (tools/docgate/docgate.py).

Each case builds a throwaway git repository, runs the gate on it as CI does and checks
the reported gaps and the exit status. Go and Rust cases need the matching helper: a
toolchain on PATH or a prebuilt binary in DOCGATE_GODOC / DOCGATE_RSDOC; without one
they are skipped with that reason (the gate itself fails closed in that situation).

Run: python3 -m unittest discover -s tools/docgate -p "test_*.py"
"""

import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parent / "docgate.py"
HAS_GO = bool(os.environ.get("DOCGATE_GODOC")) or shutil.which("go") is not None
HAS_RUST = bool(os.environ.get("DOCGATE_RSDOC")) or shutil.which("cargo") is not None


class Repo:
    """A throwaway git repository the gate runs on."""

    def __init__(self, files: dict[str, str], exclude: str | None = None):
        self.dir = Path(tempfile.mkdtemp(prefix="docgate-test-"))
        for rel, text in files.items():
            p = self.dir / rel
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")
        if exclude is not None:
            (self.dir / ".docgate-exclude").write_text(
                textwrap.dedent(exclude), encoding="utf-8"
            )
        subprocess.run(["git", "init", "-q", str(self.dir)], check=True)
        subprocess.run(["git", "-C", str(self.dir), "add", "-A"], check=True)

    def run(self, env: dict | None = None) -> tuple[int, list[str], str]:
        """Run the gate; return (exit status, reported gap lines, stderr)."""
        res = subprocess.run(
            [sys.executable, str(GATE), "--root", str(self.dir)],
            capture_output=True,
            text=True,
            env={**os.environ, **(env or {})},
        )
        gaps = [
            line for line in res.stdout.splitlines() if not line.startswith("docgate:")
        ]
        return res.returncode, gaps, res.stderr

    def close(self) -> None:
        """Remove the repository."""
        shutil.rmtree(self.dir, ignore_errors=True)


class GateCase(unittest.TestCase):
    """Shared helper: run a repository and clean it up."""

    def gate(
        self, files: dict[str, str], exclude: str | None = None, env: dict | None = None
    ):
        """Build a repository from ``files``, run the gate on it and return its result."""
        repo = Repo(files, exclude)
        self.addCleanup(repo.close)
        return repo.run(env)


class PythonRules(GateCase):
    """Python: what must carry a docstring and what is exempt."""

    def test_undocumented_function_method_and_module_are_reported(self):
        code, gaps, _ = self.gate(
            {
                "a.py": '''
                def bad():
                    pass

                class C:
                    """C."""

                    def __init__(self):
                        pass

                    def m(self):
                        pass
                ''',
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            gaps,
            ["a.py:1: module docstring", "a.py:1: function bad", "a.py:10: method C.m"],
        )

    def test_declarations_inside_conditional_blocks_are_checked(self):
        code, gaps, _ = self.gate(
            {
                "a.py": '''
                """Mod."""
                import sys

                if sys.version_info >= (3, 11):
                    def in_if():
                        pass
                else:
                    def in_else():
                        pass

                try:
                    import yaml
                except ImportError:
                    class Fallback:
                        pass
                ''',
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            gaps,
            [
                "a.py:5: function in_if",
                "a.py:8: function in_else",
                "a.py:14: class Fallback",
            ],
        )

    def test_function_local_defs_and_tests_are_exempt(self):
        code, gaps, _ = self.gate(
            {
                "a.py": '''
                """Mod."""


                def outer():
                    """Outer."""

                    def local_helper():
                        pass

                    return local_helper
                ''',
                "test_a.py": "def test_x():\n    pass\n",
                "tests/helper.py": "def h():\n    pass\n",
            }
        )
        self.assertEqual((code, gaps), (0, []))


class ExcludeFile(GateCase):
    """The exclude file: reasons are mandatory, matching files are skipped."""

    def test_excluded_file_is_not_checked(self):
        code, gaps, _ = self.gate(
            {"vendored.py": "def f():\n    pass\n"},
            exclude="# Copied from upstream, documented there.\nvendored.py\n",
        )
        self.assertEqual((code, gaps), (0, []))

    def test_exclusion_without_reason_is_refused(self):
        code, _, err = self.gate(
            {"vendored.py": "def f():\n    pass\n"},
            exclude="# Header.\n\nvendored.py\n",
        )
        self.assertEqual(code, 2)
        self.assertIn("has no reason", err)


@unittest.skipUnless(HAS_GO, "needs `go` or DOCGATE_GODOC")
class GoRules(GateCase):
    """Go: declarations, groups, directives, package docs."""

    def test_undocumented_declarations_are_reported(self):
        code, gaps, _ = self.gate(
            {
                "p/p.go": """
                // Package p is a sample.
                package p

                // Ok is documented.
                func Ok() {}

                func bad() {}

                const (
                	// A is documented.
                	A = 1
                	B = 2
                )

                //go:embed x
                var onlyDirective string
                """,
                "p/p_test.go": "package p\n\nfunc helper() {}\n",
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            gaps,
            [
                "p/p.go:7: func bad",
                "p/p.go:12: const B",
                "p/p.go:16: var onlyDirective",
            ],
        )

    def test_package_doc_in_any_file_of_a_large_package_counts(self):
        files = {
            f"big/f{i:03}.go": f"package big\n\n// F{i} is documented.\nfunc F{i}() {{}}\n"
            for i in range(250)
        }
        files["big/f249.go"] = (
            "// Package big has its doc in its last file.\npackage big\n\n// F249 is documented.\nfunc F249() {}\n"
        )
        code, gaps, _ = self.gate(files)
        self.assertEqual((code, gaps), (0, []))

    def test_missing_package_doc_is_reported_once(self):
        code, gaps, _ = self.gate(
            {
                "q/a.go": "package q\n\n// A is documented.\nfunc A() {}\n",
                "q/b.go": "package q\n\n// B is documented.\nfunc B() {}\n",
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(gaps, ["q/a.go:1: package doc (q, q)"])

    def test_a_helper_that_prints_nothing_fails_closed(self):
        code, _, err = self.gate(
            {"p/p.go": "// Package p.\npackage p\n"},
            env={"DOCGATE_GODOC": shutil.which("true") or "/bin/true"},
        )
        self.assertEqual(code, 2)
        self.assertIn("no JSON list", err)


@unittest.skipUnless(HAS_RUST, "needs `cargo` or DOCGATE_RSDOC")
class RustRules(GateCase):
    """Rust: items, impls, test code and what counts as a doc."""

    def test_undocumented_items_are_reported(self):
        code, gaps, _ = self.gate(
            {
                "src/lib.rs": """
                //! Crate doc.

                /// Ok.
                pub fn ok() {}
                fn bad() {}
                /// S.
                struct S;
                impl S {
                    fn m(&self) {}
                }
                impl Clone for S {
                    fn clone(&self) -> S { S }
                }
                #[cfg(test)]
                mod tests {
                    fn t() {}
                }
                """,
                "src/other.rs": "fn nodoc_file() {}\n",
                "tests/it.rs": "fn integration() {}\n",
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            gaps,
            [
                "src/lib.rs:5: fn bad",
                "src/lib.rs:9: method S::m",
                "src/other.rs:1: file inner doc (//!)",
                "src/other.rs:1: fn nodoc_file",
            ],
        )

    def test_doc_hidden_alone_is_not_documentation(self):
        code, gaps, _ = self.gate(
            {
                "src/lib.rs": """
                //! Crate doc.

                #[doc(hidden)]
                pub fn hidden_only() {}

                /// Documented and hidden.
                #[doc(hidden)]
                pub fn documented_hidden() {}

                #[doc = ""]
                pub fn blank_doc() {}

                #[doc = include_str!("x.md")]
                pub fn from_file() {}
                """,
            }
        )
        self.assertEqual(code, 1)
        self.assertEqual(
            gaps, ["src/lib.rs:4: fn hidden_only", "src/lib.rs:11: fn blank_doc"]
        )


if __name__ == "__main__":
    unittest.main()
