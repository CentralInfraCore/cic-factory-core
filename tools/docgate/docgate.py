#!/usr/bin/env python3
"""Documentation gate: every non-test declaration of the repository has a doc comment.

The CIC knowledge base reads code only through companion YAMLs whose descriptions come
from doc comments, so an undocumented declaration is invisible to it. This gate fails
(exit 1) when any tracked, non-excluded source file has a declaration without one:

- Python (stdlib ``ast``): the module docstring, every class, function and method
  (dunder methods excepted); test files are skipped.
- Go (``godoc/``, stdlib go/ast): every top-level func, method, type, var and const of a
  non-test file, and one package doc per package.
- Rust (``rsdoc/``, syn): every fn, inherent method, struct, enum, union, trait, type
  alias, const, static, macro_rules and foreign item, plus the file's ``//!`` inner doc;
  impl blocks, trait-impl methods (they inherit the trait's doc), modules (their file
  carries the doc) and test code are skipped.

Usage:
    python3 tools/docgate/docgate.py [--exclude-file .docgate-exclude] [--root DIR]

The exclude file lists fnmatch globs of repository-relative paths, one per line (``#``
starts a comment): template copies documented upstream, pinned or vendored files.
Fail closed: if Go or Rust files are present but ``go`` / ``cargo`` is missing, the gate
exits 2 instead of passing silently. ``DOCGATE_GODOC`` / ``DOCGATE_RSDOC`` may name a
prebuilt helper binary instead (for a machine without that toolchain).
"""

import argparse
import ast
import fnmatch
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path, PurePosixPath

HERE = Path(__file__).resolve().parent
SKIP_PARTS = {"vendor", "testdata", "target", "node_modules"}


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
    """Read the exclude globs of ``path`` (missing file: none)."""
    if not path.is_file():
        return []
    globs = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.split("#", 1)[0].strip()
        if line:
            globs.append(line)
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

        def walk(body, owner=""):
            for n in body:
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    dunder = n.name.startswith("__") and n.name.endswith("__")
                    if not dunder and not ast.get_docstring(n):
                        kind = (
                            "class"
                            if isinstance(n, ast.ClassDef)
                            else ("method" if owner else "function")
                        )
                        name = f"{owner}.{n.name}" if owner else n.name
                        gaps.append(f"{rel}:{n.lineno}: {kind} {name}")
                    if isinstance(n, ast.ClassDef):
                        walk(n.body, n.name)

        walk(tree.body)
    return gaps


def run_helper(cmd: list[str], files: list[str], root: Path, tool: str) -> list[str]:
    """Run a language helper on ``files`` (in batches) and return the gaps it prints as JSON."""
    gaps = []
    for i in range(0, len(files), 200):
        res = subprocess.run(
            cmd + files[i : i + 200], cwd=root, capture_output=True, text=True
        )
        if res.returncode != 0:
            print(f"docgate: the {tool} helper failed:\n{res.stderr}", file=sys.stderr)
            sys.exit(2)
        gaps += json.loads(res.stdout or "[]")
    return gaps


def go_gaps(root: Path, files: list[str]) -> list[str]:
    """The undocumented declarations of the given Go files, via the go/ast helper."""
    if not files:
        return []
    if os.environ.get("DOCGATE_GODOC"):
        return run_helper([os.environ["DOCGATE_GODOC"]], files, root, "Go")
    if shutil.which("go") is None:
        print("docgate: Go files are present but `go` is not on PATH", file=sys.stderr)
        sys.exit(2)
    helper = HERE / "godoc"
    out = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "docgate-godoc"
    res = subprocess.run(
        ["go", "build", "-o", str(out), "."], cwd=helper, capture_output=True, text=True
    )
    if res.returncode != 0:
        print(f"docgate: building godoc failed:\n{res.stderr}", file=sys.stderr)
        sys.exit(2)
    return run_helper([str(out)], files, root, "Go")


def rust_gaps(root: Path, files: list[str]) -> list[str]:
    """The undocumented items of the given Rust files, via the syn helper."""
    if not files:
        return []
    if os.environ.get("DOCGATE_RSDOC"):
        return run_helper([os.environ["DOCGATE_RSDOC"]], files, root, "Rust")
    if shutil.which("cargo") is None:
        print(
            "docgate: Rust files are present but `cargo` is not on PATH",
            file=sys.stderr,
        )
        sys.exit(2)
    manifest = HERE / "rsdoc" / "Cargo.toml"
    target = Path(os.environ.get("RUNNER_TEMP", "/tmp")) / "docgate-rsdoc-target"
    res = subprocess.run(
        [
            "cargo",
            "build",
            "--release",
            "--locked",
            "--quiet",
            "--manifest-path",
            str(manifest),
            "--target-dir",
            str(target),
        ],
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        print(f"docgate: building rsdoc failed:\n{res.stderr}", file=sys.stderr)
        sys.exit(2)
    return run_helper([str(target / "release" / "rsdoc")], files, root, "Rust")


def main() -> int:
    """Check the repository and print every gap; return 1 if there is any."""
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--root", default=".", help="repository root (default: .)")
    ap.add_argument(
        "--exclude-file",
        default=".docgate-exclude",
        help="exclude globs, relative to the root (default: .docgate-exclude)",
    )
    a = ap.parse_args()
    root = Path(a.root).resolve()
    globs = load_excludes(root / a.exclude_file)
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
    for g in gaps:
        print(g)
    print(
        f"docgate: {len(py)} Python, {len(go)} Go, {len(rs)} Rust files checked; "
        f"{len(gaps)} undocumented declaration(s)"
    )
    return 1 if gaps else 0


if __name__ == "__main__":
    sys.exit(main())
