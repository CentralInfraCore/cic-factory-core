#!/usr/bin/env python3
"""Documentation gate: every non-test declaration of the repository has a doc comment.

The CIC knowledge base reads code only through companion YAMLs whose descriptions come
from doc comments, so an undocumented declaration is invisible to it. This gate fails
(exit 1) when any tracked, non-excluded source file has a declaration without one:

- Python (stdlib ``ast``): the module docstring, and every class, function and method
  declared at module or class level - including inside ``if`` / ``try`` / ``with`` /
  ``match`` blocks there (e.g. ``if TYPE_CHECKING:``). Functions local to a function
  body are not declarations of the module and are not checked (the companion
  generators do not list them either). Dunder methods and test files are skipped.
- Go (``godoc/``, stdlib go/ast): every top-level func, method, type, var and const of a
  non-test file, and one package doc per package; directive-only comments do not count.
- Rust (``rsdoc/``, syn): every fn, inherent method, struct, enum, union, trait, type
  alias, const, static, macro_rules and foreign item, plus the file's ``//!`` inner doc;
  only a non-empty ``#[doc = ...]`` counts (``#[doc(hidden)]`` alone does not). Impl
  blocks, trait-impl methods (they inherit the trait's doc), modules (their file carries
  the doc) and test code are skipped.

Usage:
    python3 tools/docgate/docgate.py [--exclude-file .docgate-exclude] [--root DIR]

The exclude file lists fnmatch globs of repository-relative paths, one per line, in
blocks separated by blank lines; every block must hold a ``#`` comment giving the
reason, otherwise the gate refuses to run (exit 2).

Fail closed (exit 2): Go or Rust files present but no ``go`` / ``cargo``, a helper that
fails or prints anything but a JSON list, an exclude glob without a reason.
``DOCGATE_GODOC`` / ``DOCGATE_RSDOC`` may name a prebuilt helper binary instead of
building it (for a machine without that toolchain).
"""

import argparse
import ast
import atexit
import fnmatch
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
SKIP_PARTS = {"vendor", "testdata", "target", "node_modules"}
BLOCK_STMTS = tuple(
    getattr(ast, n)
    for n in ("If", "Try", "TryStar", "With", "AsyncWith", "Match")
    if hasattr(ast, n)
)


class GateError(Exception):
    """The gate cannot give a verdict (configuration or helper failure): exit 2."""


def tracked_files(root: Path) -> list[str]:
    """Return the repository-relative paths ``git ls-files`` reports under ``root``."""
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [f for f in out.split("\0") if f]


def load_excludes(path: Path) -> list[str]:
    """Read the exclude globs of ``path`` (missing file: none).

    Raises GateError for a glob whose block (lines up to the next blank line) holds no
    ``#`` comment before it: every exception must say why it exists.
    """
    if not path.is_file():
        return []
    globs: list[str] = []
    block_has_reason = False
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line:
            block_has_reason = False
            continue
        if line.startswith("#"):
            block_has_reason = True
            continue
        if not block_has_reason:
            raise GateError(
                f"{path.name}:{n}: exclusion {line!r} has no reason "
                "(put a # comment above it, in its block)"
            )
        globs.append(line.split("#", 1)[0].strip())
    return globs


def excluded(rel: str, globs: list[str]) -> bool:
    """Whether ``rel`` matches an exclude glob or lies in a skipped directory."""
    if SKIP_PARTS & set(PurePosixPath(rel).parts):
        return True
    return any(fnmatch.fnmatch(rel, g) for g in globs)


def is_py_test(rel: str) -> bool:
    """Whether a Python file is test code: test_*.py, *_test.py, conftest.py or under tests/."""
    p = PurePosixPath(rel)
    return (
        p.name.startswith("test_")
        or p.name.endswith("_test.py")
        or p.name == "conftest.py"
        or "tests" in p.parts
    )


def _block_bodies(node: ast.stmt) -> list[list[ast.stmt]]:
    """The statement lists of a compound block (not a def): branches, handlers, cases."""
    bodies = [getattr(node, a, []) for a in ("body", "orelse", "finalbody")]
    bodies += [h.body for h in getattr(node, "handlers", [])]
    bodies += [c.body for c in getattr(node, "cases", [])]
    return [b for b in bodies if b]


def python_gaps(root: Path, files: list[str]) -> list[str]:
    """The undocumented declarations of the given Python files, one ``path:line: what`` each."""
    gaps = []
    for rel in files:
        try:
            tree = ast.parse((root / rel).read_text(encoding="utf-8"), filename=rel)
        except (SyntaxError, UnicodeDecodeError) as e:
            gaps.append(f"{rel}:1: cannot be parsed ({e})")
            continue
        if not ast.get_docstring(tree):
            gaps.append(f"{rel}:1: module docstring")

        def walk(body: list[ast.stmt], owner: str = "") -> None:
            for n in body:
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    dunder = n.name.startswith("__") and n.name.endswith("__")
                    if not dunder and not ast.get_docstring(n):
                        if isinstance(n, ast.ClassDef):
                            kind = "class"
                        else:
                            kind = "method" if owner else "function"
                        name = f"{owner}.{n.name}" if owner else n.name
                        gaps.append(f"{rel}:{n.lineno}: {kind} {name}")
                    if isinstance(n, ast.ClassDef):
                        walk(n.body, n.name)
                elif isinstance(n, BLOCK_STMTS):
                    for b in _block_bodies(n):
                        walk(b, owner)

        walk(tree.body)
    return gaps


def run_helper(cmd: list[str], files: list[str], root: Path, tool: str) -> list[str]:
    """Run a language helper on all ``files`` at once (paths on stdin, one per line).

    The helper must exit 0 and print exactly one JSON list of strings; anything else is
    a GateError, so a broken helper can never read as "no gaps".
    """
    res = subprocess.run(
        cmd, cwd=root, input="\n".join(files) + "\n", capture_output=True, text=True
    )
    if res.returncode != 0:
        raise GateError(
            f"the {tool} helper failed (exit {res.returncode}):\n{res.stderr}"
        )
    try:
        gaps = json.loads(res.stdout)
    except ValueError as e:
        raise GateError(
            f"the {tool} helper printed no JSON list ({e}): {res.stdout[:200]!r}"
        ) from e
    if not isinstance(gaps, list) or not all(isinstance(g, str) for g in gaps):
        raise GateError(
            f"the {tool} helper printed {type(gaps).__name__}, not a list of strings"
        )
    return gaps


def _scratch_dir(prefix: str) -> Path:
    """A fresh private temporary directory, removed when the gate exits."""
    d = Path(tempfile.mkdtemp(prefix=prefix))
    atexit.register(shutil.rmtree, d, True)
    return d


def go_gaps(root: Path, files: list[str]) -> list[str]:
    """The undocumented declarations of the given Go files, via the go/ast helper."""
    if not files:
        return []
    if os.environ.get("DOCGATE_GODOC"):
        return run_helper([os.environ["DOCGATE_GODOC"]], files, root, "Go")
    if shutil.which("go") is None:
        raise GateError("Go files are present but `go` is not on PATH")
    out = _scratch_dir("docgate-godoc-") / "godoc"
    res = subprocess.run(
        ["go", "build", "-o", str(out), "."],
        cwd=HERE / "godoc",
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise GateError(f"building godoc failed:\n{res.stderr}")
    return run_helper([str(out)], files, root, "Go")


def rust_gaps(root: Path, files: list[str]) -> list[str]:
    """The undocumented items of the given Rust files, via the syn helper."""
    if not files:
        return []
    if os.environ.get("DOCGATE_RSDOC"):
        return run_helper([os.environ["DOCGATE_RSDOC"]], files, root, "Rust")
    if shutil.which("cargo") is None:
        raise GateError("Rust files are present but `cargo` is not on PATH")
    target = _scratch_dir("docgate-rsdoc-")
    res = subprocess.run(
        [
            "cargo",
            "build",
            "--release",
            "--locked",
            "--quiet",
            "--manifest-path",
            str(HERE / "rsdoc" / "Cargo.toml"),
            "--target-dir",
            str(target),
        ],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise GateError(f"building rsdoc failed:\n{res.stderr}")
    return run_helper([str(target / "release" / "rsdoc")], files, root, "Rust")


def check(root: Path, exclude_file: str) -> tuple[list[str], dict[str, int]]:
    """Return the gaps of the repository at ``root`` and the number of files per language."""
    globs = load_excludes(root / exclude_file)
    # The gate's own files (identical in every repository) are not checked, so a
    # repository without Go or Rust code needs no Go or Rust toolchain for them.
    try:
        own = HERE.relative_to(root).as_posix() + "/"
    except ValueError:
        own = None
    files = [
        f
        for f in tracked_files(root)
        if not excluded(f, globs) and not (own and f.startswith(own))
    ]
    py = [f for f in files if f.endswith(".py") and not is_py_test(f)]
    go = [f for f in files if f.endswith(".go") and not f.endswith("_test.go")]
    rs = [
        f
        for f in files
        if f.endswith(".rs")
        and not ({"tests", "benches"} & set(PurePosixPath(f).parts))
    ]
    gaps = python_gaps(root, py) + go_gaps(root, go) + rust_gaps(root, rs)
    return gaps, {"Python": len(py), "Go": len(go), "Rust": len(rs)}


def main() -> int:
    """Check the repository and print every gap; return 1 if there is any, 2 on an error."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    ap.add_argument(
        "--exclude-file",
        default=".docgate-exclude",
        help="exclude globs, relative to the root (default: .docgate-exclude)",
    )
    a = ap.parse_args()
    try:
        gaps, counts = check(Path(a.root).resolve(), a.exclude_file)
    except GateError as e:
        print(f"docgate: ERROR: {e}", file=sys.stderr)
        return 2
    for g in gaps:
        print(g)
    summary = ", ".join(f"{n} {lang}" for lang, n in counts.items())
    print(f"docgate: {summary} files checked; {len(gaps)} undocumented declaration(s)")
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
