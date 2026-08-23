#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# context-monitor.sh — a hook három helyen adott értéket $(( ))-nek anélkül,
# hogy megnézte volna, szám-e. A bash az aritmetikai kifejezésben talált
# command substitutiont végrehajtja, tehát mindhárom parancsvégrehajtás volt.
# Az állapotfájlok ráadásul /tmp-ben, a job-id-ből képzett néven éltek — a
# job-id pedig nyilvános, ott van a jobs/index.yaml-ban.
#
# Minden eset egy canary fájlra méri: ha létrejön, a payload lefutott.
# A hook mindig 0-val lép ki, tehát az exit code itt nem mond semmit.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SRC/hooks/context-monitor.sh"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}

# Minden eset saját XDG_RUNTIME_DIR-t kap, hogy a valódi állapotot ne érintse.
mkenv() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/run" "$r/workdir/jobs/demo-job/output" "$r/claude/debug"
    echo "$r"
}
runhook() {
    local r="$1"
    env -i PATH="$PATH" HOME="$r/home" \
        XDG_RUNTIME_DIR="$r/run" \
        CLAUDE_CONFIG_DIR="$r/claude" \
        CIC_JOB_ID="demo-job" CIC_WORKDIR="$r/workdir" \
        bash "$HOOK" >"$r/out.log" 2>&1
    echo $?
}
statedir() { echo "$1/run/cic/ctx"; }

echo "0. Alapműködés — a hook lefut és számol"
R=$(mkenv)
check "exit 0" "0" "$(runhook "$R")"
check "  a számláló 1-re állt" "1" "$(cat "$(statedir "$R")/count-demo-job" 2>/dev/null)"
runhook "$R" >/dev/null
check "  második hívás után 2" "2" "$(cat "$(statedir "$R")/count-demo-job" 2>/dev/null)"
check "  az állapot-könyvtár 0700" "700" "$(stat -c '%a' "$(statedir "$R")" 2>/dev/null)"
check "  nem /tmp-ben van" "0" "$(ls /tmp/cic-ctx-count-demo-job 2>/dev/null | wc -l)"
rm -rf "$R"

echo
echo "1. Számláló — command substitution nem hajtódik végre"
R=$(mkenv); D=$(statedir "$R"); mkdir -p "$D"
printf 'x[$(touch %s/CANARY1)]' "$R" > "$D/count-demo-job"
runhook "$R" >/dev/null
check "a canary nem jött létre" "0" "$([ -e "$R/CANARY1" ] && echo 1 || echo 0)"
check "  a szemét értéket 0-ra ejtette, majd növelte" "1" "$(cat "$D/count-demo-job")"
rm -rf "$R"

echo
echo "2. Evakuációs cooldown timestamp — ugyanaz a sink"
R=$(mkenv); D=$(statedir "$R"); mkdir -p "$D"
printf 'x[$(touch %s/CANARY2)]' "$R" > "$D/evac-demo-job"
# 20% alatti context kell, hogy a generate_evacuation_template egyáltalán fusson
printf 'autocompact: tokens=900 effectiveWindow=1000\n' > "$R/claude/debug/d.txt"
for _ in 1 2 3; do runhook "$R" >/dev/null; done
check "a canary nem jött létre" "0" "$([ -e "$R/CANARY2" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "3. Debug log — a sed nem-illeszkedéskor a teljes sort adta vissza"
# A payloadnak a hibás token ELŐTT kell állnia: a bash balról jobbra értékel,
# és a command substitutiont akkor bontja ki, amikor odaér.
R=$(mkenv)
printf 'x[$(touch %s/CANARY3)] autocompact: effectiveWindow=1000\n' "$R" > "$R/claude/debug/d.txt"
for _ in 1 2 3; do runhook "$R" >/dev/null; done
check "a canary nem jött létre" "0" "$([ -e "$R/CANARY3" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "4. Symlink — az írás nem megy át rajta"
R=$(mkenv); D=$(statedir "$R"); mkdir -p "$D"
echo "eredeti" > "$R/outside.txt"
ln -sf "$R/outside.txt" "$D/count-demo-job"
runhook "$R" >/dev/null
check "a külső fájl érintetlen" "eredeti" "$(cat "$R/outside.txt")"
check "  a symlink helyére valódi fájl került" "1" "$([ -f "$D/count-demo-job" ] && [ ! -L "$D/count-demo-job" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "5. Nem-numerikus szemét minden állapotfájlban — a hook fut tovább"
R=$(mkenv); D=$(statedir "$R"); mkdir -p "$D"
printf 'nem szam\n' > "$D/count-demo-job"
printf '\n'          > "$D/evac-demo-job"
check "exit 0" "0" "$(runhook "$R")"
check "  a számláló újraindult" "1" "$(cat "$D/count-demo-job")"
rm -rf "$R"

echo
echo "6. XDG_RUNTIME_DIR nélkül is privát helyre esik"
R=$(mkenv)
out=$(env -i PATH="$PATH" HOME="$R/home" \
      CLAUDE_CONFIG_DIR="$R/claude" \
      CIC_JOB_ID="demo-job" CIC_WORKDIR="$R/workdir" \
      bash "$HOOK" 2>&1; echo "rc=$?")
check "exit 0" "rc=0" "$(printf '%s' "$out" | tail -1)"
check "  a HOME/.cache alá esett" "1" "$([ -f "$R/home/.cache/cic/ctx/count-demo-job" ] && echo 1 || echo 0)"
check "  az is 0700" "700" "$(stat -c '%a' "$R/home/.cache/cic" 2>/dev/null)"
rm -rf "$R"

echo
echo "7. A figyelmeztetés továbbra is megszólal"
R=$(mkenv)
printf 'autocompact: tokens=880 effectiveWindow=1000\n' > "$R/claude/debug/d.txt"
for _ in 1 2 3; do runhook "$R" >/dev/null; done
check "CRITICAL-t jelent 12%-on" "1" "$(grep -c 'EMERGENCY\|CRITICAL' "$R/out.log")"
check "  evakuációs sablon készült" "1" "$([ -s "$R/workdir/jobs/demo-job/output/context-state.md" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "Két friss debug-log egy configban → nem tippel (#42)"
# Mérve: a forrás kiválasztása tisztán mtime szerint ment, job-kötés nélkül.
# Két azonos agent-configon futó job egymás context-értékét olvashatta, és a
# rossz job kaphatott EMERGENCY-t.
R=$(mkenv)
printf 'autocompact: tokens=950 effectiveWindow=1000\n' > "$R/claude/debug/a.txt"
printf 'autocompact: tokens=100 effectiveWindow=1000\n' > "$R/claude/debug/b.txt"
for _ in 1 2 3; do runhook "$R" >/dev/null; done
check "nem ad EMERGENCY-t idegen adatból" "0" "$(grep -c 'EMERGENCY' "$R/out.log")"
# Hívásonként egy üzenet: a minden-harmadik-hívás kapu miatt három futásból
# egyszer szólal meg, nem kétszer (a ciklus két config-jelöltet néz).
check "  megmondja, hogy nem eldönthető" "1" "$(grep -c 'nem eldönthető, melyik ezé a jobé' "$R/out.log")"
rm -rf "$R"

echo
echo "  EGY friss debug-log → továbbra is olvassa"
R=$(mkenv)
printf 'autocompact: tokens=950 effectiveWindow=1000\n' > "$R/claude/debug/a.txt"
for _ in 1 2 3; do runhook "$R" >/dev/null; done
check "figyelmeztet a fogyó contextre" "1" "$(grep -c 'EMERGENCY\|CRITICAL' "$R/out.log")"
check "  nem mondja kétértelműnek" "0" "$(grep -c 'nem eldönthető' "$R/out.log")"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
