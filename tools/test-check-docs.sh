#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# check-docs.sh mindkét szabálya, olyan fixture-ökön, amik szándékosan sértik.
# A repón futtatva ma zöld — az önmagában nem bizonyítja, hogy tud pirosat adni.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}
check_log() {
    if grep -qF -- "$2" "$3"; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — nem található: '$2'"; ((fail++)); fi
}

# Külön git repo, hogy a `git ls-files` a fixture-t lássa és ne az igazit.
mkroot() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/tools" "$r/jobs/.schema" "$r/.claude/commands"
    cp "$SRC/check-docs.sh" "$r/tools/"
    printf 'job_id: ""\nstatus: "pending"\n' > "$r/jobs/.schema/meta.yaml"
    # D3/D4 a README-t, a szabály-forrásokat és a kézi deklarációt olvassa.
    printf '# Fixture\n' > "$r/README.md"
    printf 'K1 K3\n' > "$r/tools/validate-spec.sh"
    printf 'O1 O5\n' > "$r/tools/validate-output.sh"
    printf 'refuse "C1 — x"\nrefuse "C5 — y"\n' > "$r/tools/close-job.sh"
    printf '# job-close\n\n| C1 | x |\n| C5 | y |\n' > "$r/.claude/commands/job-close.md"
    printf '# job-validate\n\n<!-- manual-rules: K2 -->\n' > "$r/.claude/commands/job-validate.md"
    git -C "$r" init -q
    git -C "$r" config user.email t@t; git -C "$r" config user.name t
    echo "$r"
}
commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" commit -qm x --no-verify >/dev/null 2>&1; }
run() { bash "$1/tools/check-docs.sh" >"$1/out.log" 2>&1; echo $?; }

echo "0. Tiszta fixture → GO (különben a többi eset semmit nem mond)"
R=$(mkroot); printf '# Doc\n\nsima szöveg\n' > "$R/a.md"; commit "$R"
check "exit 0" "0" "$(run "$R")"
check_log "  GO-t mond" "check-docs: GO" "$R/out.log"
rm -rf "$R"

echo
echo "D1 — törött relatív link"
R=$(mkroot); printf '# Doc\n\n[nincs ilyen](docs/hianyzik.md)\n' > "$R/a.md"; commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a fájlt és a sort" "a.md:3" "$R/out.log"
rm -rf "$R"

echo
echo "D1 — a létező linket nem jelenti, a külsőt sem"
R=$(mkroot)
mkdir -p "$R/docs"; printf 'x\n' > "$R/docs/van.md"
printf '# Doc\n\n[van](docs/van.md)\n[web](https://example.com/nincs.md)\n[horgony](docs/van.md#szakasz)\n' > "$R/a.md"
commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo "D2 — dokumentum újradefiniálja a sémát"
R=$(mkroot)
printf '# Doc\n\n```yaml\njob_id: "x"\nstatus: "pending"\n```\n' > "$R/a.md"; commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a fájlt" "a.md: yaml blokk újradefiniálja" "$R/out.log"
rm -rf "$R"

echo
echo "D2 — részleges idézés nem duplikáció"
# Egyetlen mező bemutatása legitim; csak az együttes job_id + status számít
# séma-újradefiniálásnak.
R=$(mkroot)
printf '# Doc\n\n```yaml\nstatus: "pending"\n```\n\nés prózában a job_id: is\n' > "$R/a.md"; commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo "Követetlen fájl is számít"
# A checker maga sétált bele: git add előtt GO-t adott egy törött linkes új
# fájlra. Egy ellenőrzés, ami csak a már commitolt hibát látja, épp akkor
# hallgat, amikor a legolcsóbb lenne javítani.
R=$(mkroot); printf '# Doc\n' > "$R/a.md"; commit "$R"
printf '# Uj\n\n[nincs](hianyzik.md)\n' > "$R/uj.md"   # szándékosan nem commitolva
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a követetlen fájlt" "uj.md:3" "$R/out.log"
rm -rf "$R"

echo
echo "Ignorált fájlt viszont nem néz"
R=$(mkroot); printf '# Doc\n' > "$R/a.md"; printf 'skip/\n' > "$R/.gitignore"; commit "$R"
mkdir -p "$R/skip"; printf '# Skip\n\n[nincs](hianyzik.md)\n' > "$R/skip/b.md"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo "A job-instance-ok archívum, nem forrás"
# A jobs/<id>/ alatt agent által termelt artifact van, a maga korának szabályai
# szerint. Utólag rájuk kényszeríteni egy később kitalált szabályt annyi lenne,
# mint átírni a bizonyítékot.
R=$(mkroot)
mkdir -p "$R/jobs/valami/output"
printf '# Output\n\n[nincs](hianyzik.md)\n\n```yaml\njob_id: "x"\nstatus: "done"\n```\n' \
    > "$R/jobs/valami/output/report.md"
printf '# Doc\n' > "$R/a.md"; commit "$R"
check "a job-artifact hibáit nem jelenti" "0" "$(run "$R")"

# A séma viszont NEM artifact — az a kontraktus, arra érvényes a szabály.
printf '# Doc\n\n[nincs](hianyzik.md)\n' > "$R/jobs/.schema/README.md"; commit "$R"
check "  a jobs/.schema/ viszont számít" "1" "$(run "$R")"
rm -rf "$R"

echo
echo "D2 — a séma maga nem sérti a saját szabályát"
R=$(mkroot); printf '# Doc\n' > "$R/a.md"; commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo
echo "D3 — suite-fájl README-sor nélkül"
R=$(mkroot); printf '#!/usr/bin/env bash\n' > "$R/tools/test-valami.sh"; commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a fájlt" "tools/test-valami.sh — van fájl, nincs README-sor" "$R/out.log"
rm -rf "$R"

echo
echo "D3 — README-sor fájl nélkül"
R=$(mkroot)
printf '# Fixture\n\n| `tools/test-nincs.sh` | valami (3 checks) |\n' > "$R/README.md"
commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a sort" "tools/test-nincs.sh — van README-sor, nincs fájl" "$R/out.log"
rm -rf "$R"

echo
echo "D3 — a párban álló fájl és sor rendben"
R=$(mkroot)
printf '#!/usr/bin/env bash\n' > "$R/tools/test-jo.sh"
printf '# Fixture\n\n| `tools/test-jo.sh` | valami (3 checks) |\n' > "$R/README.md"
commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo "D3 — átvevő repóban a hiányzó táblázat nem hiba"
R=$(mkroot); printf '#!/usr/bin/env bash\n' > "$R/tools/test-valami.sh"
printf 'schema_version: "1.0"\n' > "$R/dependency.yaml"
commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo
echo "  ugyanez dependency.yaml nélkül (a mag) → hiba"
R=$(mkroot); printf '#!/usr/bin/env bash\n' > "$R/tools/test-valami.sh"; commit "$R"
check "exit 1" "1" "$(run "$R")"
rm -rf "$R"

echo
echo "D4 — nem létező szabályra hivatkozó tartomány"
R=$(mkroot); printf '# Fixture\n\nkapu (K1–K3)\n' > "$R/README.md"; commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a hiányzót" "K2-et ígér" "$R/out.log"
rm -rf "$R"

echo
echo "D4 — nem létező szabály egyedi hivatkozása"
R=$(mkroot); printf '# Fixture\n\nlásd C4\n' > "$R/README.md"; commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi" "C4 nincs a tools/close-job.sh-ben" "$R/out.log"
rm -rf "$R"

echo
echo "D4 — kézi szabály a saját listájában rendben, máshol nem"
R=$(mkroot)
printf '# job-validate\n\n<!-- manual-rules: K2 -->\n\n### K2 — kézi\n' > "$R/.claude/commands/job-validate.md"
commit "$R"
check "a saját listájában exit 0" "0" "$(run "$R")"
printf '# Fixture\n\nkapu: K2\n' > "$R/README.md"; commit "$R"
check "  a README-ben exit 1" "1" "$(run "$R")"
check_log "  meg is mondja miért" "csak a .claude/commands/job-validate.md listájában" "$R/out.log"
rm -rf "$R"

echo
echo "D4 — elavult kézi deklaráció (közben implementálva lett)"
R=$(mkroot)
printf 'K1 K2 K3\n' > "$R/tools/validate-spec.sh"
commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi" "K2 kéziként van deklarálva" "$R/out.log"
rm -rf "$R"

echo
echo "D5 — kikényszerített szabály dokumentáció nélkül"
# A C6 (#43) olyat kért a review.md-től, amit egyik parancs sem mondott: a kapu
# elutasított valamiért, amit sehol nem lehetett megtudni.
R=$(mkroot)
printf 'refuse "C1 — x"\nrefuse "C9 — dokumentalatlan"\n' > "$R/tools/close-job.sh"
printf '# job-close\n\n| C1 | x |\n' > "$R/.claude/commands/job-close.md"
commit "$R"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a szabalyt" "kikényszeríti a C9-t, de nincs dokumentálva" "$R/out.log"
rm -rf "$R"

echo
echo "  ugyanez dokumentálva → GO"
R=$(mkroot)
printf 'refuse "C1 — x"\nrefuse "C9 — most mar leirva"\n' > "$R/tools/close-job.sh"
printf '# job-close\n\n| C1 | x |\n| C9 | most mar leirva |\n' > "$R/.claude/commands/job-close.md"
commit "$R"
check "exit 0" "0" "$(run "$R")"
rm -rf "$R"

echo "==== $pass PASS / $fail FAIL ===="
[[ "$fail" -eq 0 ]]
