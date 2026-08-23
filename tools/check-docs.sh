#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# check-docs.sh — két dolgot néz, mindkettő olyan hiba, ami már megtörtént.
#
#   D1  nincs törött relatív markdown-link
#       Az extraction után négy volt belőlük: a CLAUDE.md kötelező olvasásként
#       hivatkozott egy fájlra, ami nem jött át, egy másik pedig a repón kívülre
#       mutatott.
#
#   D2  egyetlen dokumentum sem definiálja újra a meta.yaml sémáját
#       A CLAUDE.md felsorolta a mezőket, aztán a séma három mezővel előrement
#       (lease_expires, spec_gate, usage) és a másolat hallgatott róluk. Egy
#       séma, amit két helyen írunk le, egy helyen elavul.
#
#   D3  a README suite-táblázata a valódi fájlokat sorolja
#       A táblázat és a tools/ két külön, kézzel karbantartott lista volt.
#
#   D4  a dokumentált K/O/C szabályok léteznek
#       Három dokumentum ígért "K1–K11"-et. Kilenc volt belőle: a K2, K5 és K6
#       sehol nem létezett. Egy tartomány olyan állítás, amit senki nem
#       ellenőrzött — ezt nézi ez a szabály.
#
#   D5  az implementált K/O/C szabályok dokumentálva vannak
#       A D4 fordítottja. A C6 (#43) olyat kért a review.md-től, amit a
#       /job-review és a /job-close egyik sem mondott — a kapu elutasított
#       valamiért, amit sehol nem lehetett megtudni. Ugyanaz az osztály, mint
#       a #58 FACTORY_PROMPT_VARS-a: egy követelmény, ami nincs kimondva, nem
#       követelmény, hanem csapda.
#
# Exit 0 = rendben, exit 1 = van hiba.

set -uo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKDIR" || exit 1

FAILED=0

echo "D1 — relatív markdown-linkek"
BROKEN=$(python3 - <<'PY'
import os, re, subprocess


def is_job_artifact(path):
    # jobs/<id>/... is an archive: specs, agent output, reviews, produced under
    # whatever rules applied at the time. Retroactively editing it to satisfy a
    # rule invented later would damage the evidence it exists to preserve.
    # jobs/.schema/ is not an artifact -- it is the contract.
    parts = path.split("/")
    return len(parts) > 2 and parts[0] == "jobs" and parts[1] != ".schema"


def tracked_md():
    # --others --exclude-standard so a new file is checked before it is added.
    # Without it the checker returns GO on a document whose links are broken and
    # only notices after `git add`, which is a trap it walked into itself.
    out = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
        text=True).split()
    return sorted({f for f in out if not is_job_artifact(f)})


out = []
for f in tracked_md():
    base = os.path.dirname(f)
    with open(f, encoding="utf-8") as fh:
        for i, line in enumerate(fh, 1):
            for m in re.finditer(r'\[([^\]]*)\]\(([^)]+)\)', line):
                t = m.group(2).split('#')[0].strip()
                if not t or t.startswith(("http://", "https://", "mailto:")):
                    continue
                if not os.path.exists(os.path.normpath(os.path.join(base, t))):
                    out.append(f"  {f}:{i} → {m.group(2)}")
print("\n".join(out))
PY
)
if [[ -n "$BROKEN" ]]; then
    echo "$BROKEN"
    echo "  FAIL — törött link"
    FAILED=1
else
    echo "  OK — nincs törött link"
fi

echo
echo "D2 — a meta.yaml sémája egy helyen él"
DUPES=$(python3 - <<'PY'
import re, subprocess
# A séma jellemzője: egy yaml blokk, amiben együtt szerepel a job_id és a status
# top-level kulcs. Prózában idézett egyetlen mezőnév nem duplikáció.
pat = re.compile(r'```ya?ml\n(.*?)```', re.S)
out = []
def is_job_artifact(path):
    parts = path.split("/")
    return len(parts) > 2 and parts[0] == "jobs" and parts[1] != ".schema"


files = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
    text=True).split()
for f in sorted({x for x in files if not is_job_artifact(x)}):
    body = open(f, encoding="utf-8").read()
    for block in pat.findall(body):
        has_job = re.search(r'^job_id:', block, re.M)
        has_status = re.search(r'^status:', block, re.M)
        if has_job and has_status:
            out.append(f"  {f}: yaml blokk újradefiniálja a sémát")
print("\n".join(out))
PY
)
if [[ -n "$DUPES" ]]; then
    echo "$DUPES"
    echo "  FAIL — a sémát a jobs/.schema/meta.yaml definiálja; a dokumentum hivatkozzon rá"
    FAILED=1
else
    echo "  OK — egyetlen dokumentum sem definiálja újra"
fi

echo
echo "D3 — a README suite-táblázata a valódi fájlokat sorolja"
DRIFT=$(python3 - <<'PYD3'
import os, re, subprocess
files = set(subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "tools/test-*.sh"],
    text=True).split())
rows = set("tools/" + m for m in re.findall(
    r'^\| `tools/(test-[A-Za-z0-9._-]+\.sh)`',
    open("README.md", encoding="utf-8").read(), re.M))

# Ez a szabály a README ÁLLÍTÁSAIT ellenőrzi. Egy átvevő repó örökli az
# eszközöket, de nem az állításokat: a saját READMEjében nincs suite-táblázat,
# és nem is kell lennie. A dependency.yaml jelzi, hogy ez egy átvevő -- a mag
# maga nem hordoz ilyet. A magban a táblázat hiánya továbbra is hiba.
if not rows and os.path.exists("dependency.yaml"):
    print("")
    raise SystemExit(0)
out = [f"  {f} — van fájl, nincs README-sor" for f in sorted(files - rows)]
out += [f"  {r} — van README-sor, nincs fájl" for r in sorted(rows - files)]
print("\n".join(out))
PYD3
)
if [[ -n "$DRIFT" ]]; then
    echo "$DRIFT"
    echo "  FAIL — a táblázat és a tools/ nem ugyanazt mondja"
    FAILED=1
else
    echo "  OK — minden suite pontosan egyszer szerepel"
fi

echo
echo "D4 — a dokumentált kapuszabályok léteznek"
MISSING=$(python3 - <<'PYD4'
import re, subprocess

SOURCES = {"K": "tools/validate-spec.sh",
           "O": "tools/validate-output.sh",
           "C": "tools/close-job.sh"}
impl = {}
for letter, path in SOURCES.items():
    try:
        body = open(path, encoding="utf-8").read()
    except OSError:
        body = ""
    impl[letter] = set(re.findall(r"\b(" + letter + r"\d+b?)\b", body))

# A /job-validate kezi listaja tobb, mint amit a gepi kapu ellenoriz: K2, K5 es
# K6 megitelesi kerdes, azokat nem dont el grep. Ezek deklaralva vannak, hogy a
# hivatkozasuk ne latszodjon driftnek -- de a deklaracio maga is ellenorzott.
MANUAL_DECL = ".claude/commands/job-validate.md"
manual = set()
try:
    m = re.search(r"<!--\s*manual-rules:\s*([^>]*?)-->",
                  open(MANUAL_DECL, encoding="utf-8").read())
    if m:
        manual = set(m.group(1).split())
except OSError:
    pass

stale = [i for i in sorted(manual) if i and i[0] in impl and i in impl[i[0]]]

docs = subprocess.check_output(
    ["git", "ls-files", "--cached", "--others", "--exclude-standard", "*.md"],
    text=True).split()


def is_job_artifact(path):
    parts = path.split("/")
    return len(parts) > 2 and parts[0] == "jobs" and parts[1] != ".schema"


out = []
for doc in sorted(d for d in docs if not is_job_artifact(d)):
    for i, line in enumerate(open(doc, encoding="utf-8").read().split("\n"), 1):
        # Tartomány (K1–K11): minden köztes azonosítót ígér.
        for letter, lo, hi in re.findall(r"\b([KOC])(\d+)\s*[–-]\s*[KOC]?(\d+)\b", line):
            for n in range(int(lo), int(hi) + 1):
                ident = letter + str(n)
                # A kézi szabály CSAK a saját listájában elfogadható. Máshol --
                # például a README "machine gate (K1–K11)" mondatában -- épp az
                # a hiba, hogy gépinek állít valamit, ami megítélési kérdés.
                allowed = ident in impl[letter] or (ident in manual and doc == MANUAL_DECL)
                if not allowed:
                    out.append(f"  {doc}:{i} — a {letter}{lo}–{letter}{hi} tartomány "
                               f"{ident}-et ígér, de az nincs a {SOURCES[letter]}-ben")
        # Egyedi hivatkozás.
        for ident in re.findall(r"(?<![A-Za-z0-9])([KOC]\d+b?)(?![A-Za-z0-9])", line):
            if ident in impl[ident[0]]:
                continue
            if ident in manual and doc == MANUAL_DECL:
                continue
            if ident in manual:
                out.append(f"  {doc}:{i} — {ident} kézi szabály, csak a "
                           f"{MANUAL_DECL} listájában hivatkozható")
            else:
                out.append(f"  {doc}:{i} — {ident} nincs a {SOURCES[ident[0]]}-ben, "
                           f"és nincs kéziként deklarálva ({MANUAL_DECL})")

# Elavult deklaráció: ami kéziként szerepel, de közben implementálva lett.
for ident in stale:
    out.append(f"  {MANUAL_DECL} — {ident} kéziként van deklarálva, "
               f"de már implementálva van a {SOURCES[ident[0]]}-ben")
print("\n".join(sorted(set(out))))
PYD4
)
if [[ -n "$MISSING" ]]; then
    echo "$MISSING"
    echo "  FAIL — a dokumentáció olyan szabályra hivatkozik, ami nincs implementálva"
    FAILED=1
else
    echo "  OK — minden hivatkozott K/O/C szabály létezik"
fi

echo
echo "D5 — az implementált kapuszabályok dokumentálva vannak"
UNDOC=$(python3 - <<'PYD5'
import os
import re

# Melyik script melyik szabálybetűt implementálja, és hol kell dokumentálva lennie.
PAIRS = [("C", "tools/close-job.sh",
          [".claude/commands/job-close.md"]),
         ("O", "tools/validate-output.sh",
          [".claude/commands/job-close.md", ".claude/commands/job-review.md"]),
         ("K", "tools/validate-spec.sh",
          [".claude/commands/job-validate.md"])]

out = []
for letter, impl, docs in PAIRS:
    try:
        body = open(impl, encoding="utf-8").read()
    except OSError:
        continue
    # Csak az ELUTASÍTÁSOKAT nézzük: azok a kikényszerített szabályok.
    rules = set(re.findall(rf'refuse\s+"({letter}\d+b?)\b', body))
    rules |= set(re.findall(rf'NO-GO[^"\n]*\b({letter}\d+b?)\b', body))
    if not rules:
        continue
    text = ""
    for d in docs:
        if os.path.exists(d):
            text += open(d, encoding="utf-8").read()
    for rule in sorted(rules):
        if not re.search(rf'(?<![A-Za-z0-9]){rule}(?![A-Za-z0-9])', text):
            out.append(f"  {impl} kikényszeríti a {rule}-t, de nincs dokumentálva "
                       f"({', '.join(docs)})")
print("\n".join(out))
PYD5
)
if [[ -n "$UNDOC" ]]; then
    echo "$UNDOC"
    echo "  FAIL — a kapu olyat kér, amit a parancs nem mond"
    FAILED=1
else
    echo "  OK — minden kikényszerített szabály dokumentált"
fi

echo
[[ "$FAILED" -eq 0 ]] && echo "check-docs: GO" || echo "check-docs: NO-GO"
exit "$FAILED"
