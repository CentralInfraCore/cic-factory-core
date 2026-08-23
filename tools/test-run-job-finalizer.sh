#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
# Exercises run-job.sh's finalizer prelude — the real text, extracted from the
# shipped script, not a hand-copied clone. Each case runs in its own process
# with a fixture meta.yaml.
set -uo pipefail

TOOLS="$(cd "$(dirname "$0")" && pwd)"
SRC="$TOOLS/run-job.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# A case-scriptek a tools/ alá kerülnek, mert a finalizer a WORKDIR-ből
# ($0/..) keresi a testvér-eszközeit. A korábbi fixture /tmp-be tette őket,
# tehát a WORKDIR /tmp lett, és a finalizer soha nem látta a tools/-t --
# pontosan ezért volt strukturálisan vak arra, hogy az indexet nem
# regenerálja (#34).
mkdir -p "$TMP/tools" "$TMP/jobs"
cp "$TOOLS/meta-get.sh" "$TOOLS/meta-set.sh" "$TOOLS/update-index.sh" "$TMP/tools/"

# The prelude: everything up to and including the `trap finalize EXIT INT TERM`.
PRELUDE_END=$(grep -n '^trap finalize EXIT INT TERM$' "$SRC" | head -1 | cut -d: -f1)
sed -n "1,${PRELUDE_END}p" "$SRC" > "$TMP/prelude.sh"
echo "prelude: 1..$PRELUDE_END sor"

# A #41 óta a finalizer a meta run_id-jéhez köti az írási jogosultságát: csak
# az a futás veheti vissza a jobot, amelyik a running állapotot odaírta.
# A fixture metája ezért hordoz egy azonosítót, és az eseteknek ugyanezt kell
# RUN_ID-ként beállítaniuk.
FIXTURE_RUN_ID="fixture-run-0001"
mkmeta() {
    cat > "$1" <<EOF
status: "$2"
run_id: "${3-$FIXTURE_RUN_ID}"
error_message: ""
timestamps:
  created: "2026-01-01T00:00:00Z"
  started: "2026-01-01T00:00:00Z"
  completed: ""
EOF
}

pass=0; fail=0
check() { # name expected actual
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++));
    else echo "  FAIL  $1 — várt: [$2] kapott: [$3]"; ((fail++)); fi
}

run_case() { # script-body meta-status  -> prints "rc|status|stderr"
    local body="$1" st="$2"
    # __keep__: a hívó már megírta a metát (pl. sorvégi kommenttel)
    [[ "$st" == "__keep__" ]] || mkmeta "$TMP/meta.yaml" "$st"
    cat > "$TMP/tools/case.sh" <<EOF
$(cat "$TMP/prelude.sh")
META="$TMP/meta.yaml"
$body
EOF
    local err rc
    err=$(bash "$TMP/tools/case.sh" 2>&1 >/dev/null); rc=$?
    echo "$rc|$(grep '^status:' "$TMP/meta.yaml" | awk -F'"' '{print $2}')|$err"
}

echo
echo "1. Korai kilépés MIUTÁN mi állítottuk running-ra → meta error lesz"
out=$(run_case 'RUN_ID="fixture-run-0001"; RUN_LOG="'"$TMP"'/run.log"; exit 7' "running")
check "exit kód megőrizve" "7" "${out%%|*}"
check "status → error" "error" "$(echo "$out" | head -1 | cut -d'|' -f2)"
grep -q 'idő előtt kilépett' <<<"$out" && { echo "  PASS  figyelmeztetés stderr-en"; ((pass++)); } \
    || { echo "  FAIL  nincs figyelmeztetés stderr-en"; ((fail++)); }
grep -q 'wrapper exited early' "$TMP/run.log" 2>/dev/null && { echo "  PASS  napló írva"; ((pass++)); } \
    || { echo "  FAIL  a napló nem íródott ($TMP/run.log)"; ((fail++)); }
grep -q 'error_message: "wrapper exited' "$TMP/meta.yaml" && { echo "  PASS  error_message kitöltve"; ((pass++)); } \
    || { echo "  FAIL  error_message üres"; ((fail++)); }
grep -q 'completed: "20' "$TMP/meta.yaml" && { echo "  PASS  completed timestamp kitöltve"; ((pass++)); } \
    || { echo "  FAIL  completed üres"; ((fail++)); }

echo
echo "2. Idegen 'running' meta (mi NEM állítottuk) → érintetlen marad"
out=$(run_case 'exit 1' "running")
check "status változatlan" "running" "$(echo "$out" | head -1 | cut -d'|' -f2)"

echo
echo "3. Normál út: FINALIZED=1 → a trap nem ír felül"
# awaiting_review, not done: this is the state run-job.sh actually leaves behind.
# Exit 0 says the agent finished; only /job-close may say the job is acceptable.
out=$(run_case 'RUN_ID="fixture-run-0001"; FINALIZED=1; exit 0' "awaiting_review")
check "exit 0 megőrizve" "0" "${out%%|*}"
check "status változatlan" "awaiting_review" "$(echo "$out" | head -1 | cut -d'|' -f2)"

echo
echo '4. Lezárt stdout ("... | head"): a script véget ér, DE a finalizer lefut'
echo "   (ez az eredeti incidens: régen a SIGPIPE megkerülte az EXIT trapet)"
mkmeta "$TMP/meta.yaml" "running"
cat > "$TMP/tools/pipe.sh" <<EOF
$(cat "$TMP/prelude.sh")
META="$TMP/meta.yaml"
RUN_LOG="$TMP/pipe.log"
RUN_ID="fixture-run-0001"
for i in \$(seq 1 5000); do echo "sor \$i"; done
FINALIZED=1   # ide már nem jut el
EOF
bash "$TMP/tools/pipe.sh" 2>"$TMP/pipe.err" | head -3 >/dev/null
sleep 0.2
check "status → error (nem ragad running-ban)" "error" \
    "$(grep '^status:' "$TMP/meta.yaml" | awk -F'"' '{print $2}')"
grep -q 'idő előtt kilépett' "$TMP/pipe.err" && { echo "  PASS  a finalizer lefutott zárt stdout mellett is"; ((pass++)); } \
    || { echo "  FAIL  a finalizer néma maradt"; ((fail++)); }
grep -q 'error_message: "wrapper exited' "$TMP/meta.yaml" && { echo "  PASS  error_message kitöltve"; ((pass++)); } \
    || { echo "  FAIL  error_message üres"; ((fail++)); }

echo
echo "5. SIGTERM futás közben → meta error, agent PID jelentve"
mkmeta "$TMP/meta.yaml" "running"
cat > "$TMP/tools/term.sh" <<EOF
$(cat "$TMP/prelude.sh")
META="$TMP/meta.yaml"
RUN_LOG="$TMP/term.log"
RUN_ID="fixture-run-0001"
sleep 300 &
AGENT_PID=\$!
echo \$AGENT_PID > "$TMP/agent.pid"
wait \$AGENT_PID
EOF
bash "$TMP/tools/term.sh" 2>"$TMP/term.err" &
WRAPPER=$!
sleep 1
kill -TERM "$WRAPPER" 2>/dev/null
wait "$WRAPPER" 2>/dev/null
sleep 0.3
check "status → error" "error" "$(grep '^status:' "$TMP/meta.yaml" | awk -F'"' '{print $2}')"
grep -q 'MÉG FUT árván: PID' "$TMP/term.err" && { echo "  PASS  árva agent PID jelentve"; ((pass++)); } \
    || { echo "  FAIL  nincs árva-figyelmeztetés (dead code lenne)"; ((fail++)); }
AP=$(cat "$TMP/agent.pid" 2>/dev/null || echo "")
[[ -n "$AP" ]] && kill -0 "$AP" 2>/dev/null && { echo "  PASS  a háttérgyerek túlélte a wrapper TERM-jét"; ((pass++)); } \
    || { echo "  FAIL  a gyerek nem élte túl — nem lenne mit jelenteni"; ((fail++)); }
[[ -n "$AP" ]] && kill -TERM "$AP" 2>/dev/null

echo
echo "6. Git-es fixture: a kipusholt index sem mutathat futó jobot (#34)"
# Az 1-5. esetek önálló meta-fájlon futnak, git és index nélkül -- ezért nem
# láthatták, hogy a finalizer a javított meta MELLÉ a futás előtti indexet
# commitolja. Ez az eset teljes fát épít, távolival együtt.
G="$TMP/git"; mkdir -p "$G/tools" "$G/jobs/t" "$G/hooks"
cp "$TOOLS/meta-get.sh" "$TOOLS/meta-set.sh" "$TOOLS/update-index.sh" "$G/tools/"
mkmeta "$G/jobs/t/meta.yaml" "running"
python3 - "$G/jobs/t/meta.yaml" <<'PYX'
import sys
p = sys.argv[1]; c = open(p).read()
open(p, "w").write('job_id: "t"\nlevel: "repo"\n' + c)
PYX
git init -q --bare "$TMP/remote.git"
git -C "$G" init -q
git -C "$G" config user.email t@t
git -C "$G" config user.name t
git -C "$G" config commit.gpgsign false
git -C "$G" config core.hooksPath "$G/hooks"   # a valódi aláíró hook ne fusson
git -C "$G" remote add origin "$TMP/remote.git"
bash "$G/tools/update-index.sh" >/dev/null 2>&1
git -C "$G" add -A >/dev/null 2>&1
git -C "$G" commit -qm init >/dev/null 2>&1
git -C "$G" branch -M main >/dev/null 2>&1
git -C "$G" push -q -u origin main >/dev/null 2>&1

check "kiindulás: az index running-ot mond" "1" \
    "$(grep -c 'running' "$G/jobs/index.yaml")"

cat > "$G/tools/case.sh" <<EOF
$(cat "$TMP/prelude.sh")
META="$G/jobs/t/meta.yaml"
RUN_LOG="$G/run.log"
JOB_ID="t"
RUN_ID="fixture-run-0001"
exit 7
EOF
bash "$G/tools/case.sh" >/dev/null 2>"$G/case.err"

check "a meta error lett" "error" \
    "$(bash "$TOOLS/meta-get.sh" "$G/jobs/t/meta.yaml" status)"
check "  az index NEM mond running-ot" "0" "$(grep -c 'running' "$G/jobs/index.yaml")"
check "  az index error-t mond" "1" "$(grep -c 'error' "$G/jobs/index.yaml")"

# És ugyanez a távolin, mert a job-boot azt olvassa.
REMOTE_IDX=$(git -C "$G" show origin/main:jobs/index.yaml 2>/dev/null || echo "")
check "  a távoli index sem mond running-ot" "0" "$(printf '%s' "$REMOTE_IDX" | grep -c 'running')"
check "  a távoli index error-t mond" "1" "$(printf '%s' "$REMOTE_IDX" | grep -c 'error')"

# A finalizer commitja is csak a saját path-jait viheti (#63). Idegen fájlt
# stage-elünk, mielőtt a finalizer commitol.
echo "idegen munka" > "$G/IDEGEN.txt"
git -C "$G" add IDEGEN.txt
mkmeta "$G/jobs/t/meta.yaml" "running"
python3 - "$G/jobs/t/meta.yaml" <<'PYZ'
import sys
p = sys.argv[1]; c = open(p).read()
open(p, "w").write('job_id: "t"\nlevel: "repo"\n' + c)
PYZ
bash "$G/tools/case.sh" >/dev/null 2>&1
ERRC=$(git -C "$G" log --format='%H %s' | awk '/— error \(wrapper/{print $1; exit}')
check "  a finalizer commitja nem visz idegen fájlt" "0" \
    "$(git -C "$G" show --name-only --format='' "$ERRC" 2>/dev/null | grep -c '^IDEGEN.txt$')"
check "  az idegen fájl stage-elve maradt" "1" \
    "$(git -C "$G" diff --cached --name-only | grep -c '^IDEGEN.txt$')"

echo
echo "7. Idézőjel nélküli status: a finalizer akkor is javít"
# Az `awk -F'"'` olvasó erre ÜRES stringet adott, tehát a finalizer némán nem
# vette vissza a jobot -- a meta 'running'-ban ragadt. YAML szerint ez ugyanaz
# a dokumentum, mint az idézőjeles alak. Ugyanaz az osztály, mint #29/#30,
# csak itt a mulasztás a hiba.
mkmeta "$TMP/meta.yaml" "running"
sed -i 's/^status: "running"$/status: running # agent-01/' "$TMP/meta.yaml"
out=$(run_case 'RUN_ID="fixture-run-0001"; RUN_LOG="'"$TMP"'/c.log"; exit 7' "__keep__")
check "status → error" "error" "$(bash "$TOOLS/meta-get.sh" "$TMP/meta.yaml" status)"

echo
echo "==== $pass PASS / $fail FAIL ===="
[[ "$fail" -eq 0 ]]
