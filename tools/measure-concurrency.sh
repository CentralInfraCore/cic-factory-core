#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# measure-concurrency.sh — a #41 (FC-04) konkurencia-állításainak mérése.
#
# NEM teszt-suite, és szándékosan nem fut a kapuban: hosszú, több teljes
# factory-fát épít, és a kimenete emberi olvasásra való. A célja, hogy a
# tervezés MÉRT alapon álljon, ne feltételezésen — az eredményeket a SPEC.md
# UC-03/UC-05/UC-06 szakasza és a #41 kommentje rögzíti.
#
# Barrier-alapú szinkronizáció: a runner jelez, hogy elindult, és megvárja az
# engedélyt. Időzítésre épülő `sleep` nem elég egy versenyhelyzethez.
#
# Futtatás:  bash tools/measure-concurrency.sh
set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
CORE="$SRC"
ROOT="$(cd "$SRC/.." && pwd)"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
verdict() { printf '  → %s\n' "$1"; }

mkfactory() {   # <job-id...>
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo/tools/runners" "$r/repo/jobs/.schema" "$r/home/.claude-personal/agents/agent-01"
    for f in "$CORE"/*.sh; do
        [[ "$(basename "$f")" == "env.sh" ]] && continue
        cp "$f" "$r/repo/tools/"
    done
    cp "$CORE"/runners/*.sh "$r/repo/tools/runners/"
    cp "$ROOT"/jobs/.schema/*.json "$ROOT"/jobs/.schema/meta.yaml "$r/repo/jobs/.schema/"
    for job in "$@"; do
        mkdir -p "$r/repo/jobs/$job/output"
        printf '# %s\n## Output\n`output/report.md`\n' "$job" > "$r/repo/jobs/$job/input.md"
        python3 - "$r" "$job" <<'PY'
import sys, yaml
root, job = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
d["job_id"] = job; d["level"] = "repo"; d["status"] = "pending"
d["agent"]["model"] = "echo-model"
d["agent"]["config_dir"] = f"{root}/home/.claude-personal/agents/agent-01"
d["workplace"]["branch"] = f"feature/{job}"
class Q(str): pass
yaml.add_representer(Q, lambda dd,x: dd.represent_scalar("tag:yaml.org,2002:str", str(x), style='"'))
def q(o):
    if isinstance(o, dict): return {k: q(v) for k,v in o.items()}
    if isinstance(o, list): return [q(v) for v in o]
    if isinstance(o, str):  return Q(o)
    return o
yaml.dump(q(d), open(f"{root}/repo/jobs/{job}/meta.yaml","w",encoding="utf-8"),
          sort_keys=False, allow_unicode=True)
PY
    done
    # barrier-runner: jelez, majd vár
    cat > "$r/repo/tools/runners/barrier.sh" <<'RUN'
#!/usr/bin/env bash
set -uo pipefail
PROMPT_FILE="${CIC_PROMPT_FILE:?}"; RESULT_JSON="${CIC_RESULT_JSON:?}"; RUN_LOG="${CIC_RUN_LOG:?}"
echo "barrier runner: $CIC_JOB_ID elindult" >> "$RUN_LOG"
touch "${CIC_BARRIER_READY:?}.$CIC_JOB_ID.$$"
while [[ ! -f "${CIC_BARRIER_GO:?}" ]]; do sleep 0.05; done
python3 -c "
import json,sys
json.dump({'result':'kesz','models':'barrier','stop_reason':'end_turn'},
          open(sys.argv[1],'w'))" "$RESULT_JSON"
exit 0
RUN
    chmod +x "$r/repo/tools/runners/barrier.sh"
    git init -q --bare "$r/remote.git"
    git -C "$r/repo" init -q
    git -C "$r/repo" config user.email t@t; git -C "$r/repo" config user.name t
    git -C "$r/repo" config commit.gpgsign false
    mkdir -p "$r/nohooks"; git -C "$r/repo" config core.hooksPath "$r/nohooks"
    git -C "$r/repo" remote add origin "$r/remote.git"
    git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm init
    git -C "$r/repo" branch -M main; git -C "$r/repo" push -q -u origin main
    echo "$r"
}
# NEM command substitutionben hívjuk: az alhéj gyereke lenne, és a főhéj nem
# tudna wait-elni rá (127-et adna, és az állapotot túl korán olvasnánk).
LAUNCHED_PID=""
launch() {  # <root> <job> <logsuffix>
    local r="$1" job="$2" sfx="${3:-}"
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=barrier \
        CIC_BARRIER_READY="$r/ready" CIC_BARRIER_GO="$r/go" \
        bash tools/run-job.sh "$job" agent-01 --skip-spec-gate \
        </dev/null ) >"$r/$job$sfx.log" 2>&1 &
    LAUNCHED_PID=$!
}

# A `$!` az ALHÉJ pid-je, nem a run-job.sh-é. Egy `kill` rá árván hagyja a
# wrappert, ami vidáman befejezi a munkát — a 2026-08-23-i "megfigyelés",
# hogy egy megszüntetett futás utólag írt, ennek az artefaktja volt.
wrapper_pid() {  # <root> <job>
    pgrep -f "bash tools/run-job.sh $2 agent-01" | head -1
}
wait_ready() { local r="$1" n="$2" i=0
    while [[ $(ls "$r"/ready.* 2>/dev/null | wc -l) -lt "$n" ]]; do
        sleep 0.1; i=$((i+1)); [[ $i -gt 300 ]] && return 1; done; return 0; }
status_of() { bash "$CORE/meta-get.sh" "$1/repo/jobs/$2/meta.yaml" status 2>/dev/null; }

# ── 1. Két KÜLÖNBÖZŐ job párhuzamosan ───────────────────────────────────────
say "1. Két különböző job párhuzamosan (UC-05)"
R=$(mkfactory alpha beta)
launch "$R" alpha; P1=$LAUNCHED_PID
launch "$R" beta; P2=$LAUNCHED_PID
if wait_ready "$R" 2; then
    echo "  mindkét runner elindult; engedély kiadva"
else
    echo "  (nem indult el mindkettő — a második már a git műveleteknél elhalt)"
fi
touch "$R/go"; wait "$P1" 2>/dev/null; rc1=$?; wait "$P2" 2>/dev/null; rc2=$?
echo "  exit: alpha=$rc1 beta=$rc2"
echo "  státusz: alpha=$(status_of "$R" alpha) beta=$(status_of "$R" beta)"
CROSS=$(git -C "$R/repo" log --format='%s' -8 --name-only | awk '/^job:/{s=$0} /^jobs\//{split($0,a,"/"); if (s !~ a[2]) print s" → "$0}' | sort -u)
if [[ -n "$CROSS" ]]; then
    verdict "REPRODUKÁLT — kereszt-commit: egy job commitja másik job fájlját viszi"
    printf '     %s\n' "$CROSS" | head -4
else
    verdict "nem reprodukálódott kereszt-commit ebben a futásban"
fi
echo "  --- alpha log vége:"; tail -3 "$R/alpha.log" | sed 's/^/     /'
echo "  --- beta log vége:";  tail -3 "$R/beta.log"  | sed 's/^/     /'
rm -rf "$R"

# ── 2. UGYANAZ a job kétszer ────────────────────────────────────────────────
say "2. Ugyanaz a job versengő indítása (UC-06)"
R=$(mkfactory gamma)
launch "$R" gamma; P1=$LAUNCHED_PID
sleep 0.3
launch "$R" gamma "-2"; P2=$LAUNCHED_PID
wait_ready "$R" 1
touch "$R/go"; wait "$P1" 2>/dev/null; rc1=$?; wait "$P2" 2>/dev/null; rc2=$?
echo "  exit: első=$rc1 második=$rc2"


echo "  végállapot: $(status_of "$R" gamma)"
if [[ "$rc1" -eq 0 && "$rc2" -eq 0 ]]; then
    verdict "REPRODUKÁLT — mindkét indítás sikeresen lefutott ugyanarra a jobra"
else
    verdict "az egyik indítás elbukott (exit $rc1 / $rc2) — nézd meg, mi állította meg"
fi
grep -hiE 'már fut|folytatod|conflict|hiba' "$R"/gamma*.log | head -3 | sed 's/^/     /'
rm -rf "$R"

# ── 2b. Valódi egyidejűség: mindkettő azelőtt olvas, hogy bármelyik írna ────
say "2b. Ugyanaz a job, késleltetés NÉLKÜL (a valódi TOCTOU-ablak)"
HITS=0
for i in 1 2 3 4 5; do
    R=$(mkfactory delta)
    launch "$R" delta;      P1=$LAUNCHED_PID
    launch "$R" delta "-2"; P2=$LAUNCHED_PID
    wait_ready "$R" 1 >/dev/null; touch "$R/go"
    wait "$P1" 2>/dev/null; a=$?; wait "$P2" 2>/dev/null; b=$?
    if [[ "$a" -eq 0 && "$b" -eq 0 ]]; then
        HITS=$((HITS+1)); echo "  #$i: MINDKETTŐ átment"
    else
        echo "  #$i: exit $a / $b"
    fi
    rm -rf "$R"
done
if [[ "$HITS" -gt 0 ]]; then
    verdict "REPRODUKÁLT — 5-ből $HITS futásban mindkét indítás átjutott a status-ellenőrzésen"
else
    verdict "5/5-ben a második megállt; a TOCTOU-ablak szűk, de nincs zárva (olvasás és írás közt nincs CAS)"
fi

# ── 3. Ugyanaz a job: workspace törlése egymás alól ─────────────────────────
say "3. Workspace rm -rf ugyanarra a jobra"
R=$(mkfactory epsilon)
launch "$R" epsilon; P1=$LAUNCHED_PID
wait_ready "$R" 1 >/dev/null
WS="$R/home/.claude-personal/agents/agent-01/workspace/epsilon"
CANARY="$WS/cic-factory/CANARY.txt"
mkdir -p "$WS/cic-factory" 2>/dev/null
echo "az első futás munkája" > "$CANARY" 2>/dev/null
# ŐR: ami nem jött létre, azt nem lehet törölni -- enélkül a mérés akkor is
# "reprodukált"-at mondana, ha a canary sosem létezett.
if [[ ! -f "$CANARY" ]]; then
    verdict "MÉRHETETLEN — a canaryt nem sikerült elhelyezni ($CANARY)"
    rm -rf "$R"; SKIP3=1
else
    echo "  canary elhelyezve: $CANARY"
    SKIP3=0
fi
# a második indítás --resume nélkül: rm -rf a workspace-re
( cd "$R/repo" && env HOME="$R/home" CIC_AGENT_RUNNER=barrier \
    CIC_BARRIER_READY="$R/ready2" CIC_BARRIER_GO="$R/go" \
    bash tools/run-job.sh epsilon agent-01 --skip-spec-gate </dev/null ) >"$R/eps2.log" 2>&1
touch "$R/go"; wait "$P1" 2>/dev/null
if [[ "${SKIP3:-0}" -eq 1 ]]; then :
elif [[ -f "$CANARY" ]]; then
    verdict "a canary túlélte — a második indítás nem jutott el a törlésig"
else
    verdict "REPRODUKÁLT — a második indítás törölte az első futás workspace-ét"
fi
grep -hiE 'már fut|folytatod' "$R/eps2.log" | head -2 | sed 's/^/     /'
rm -rf "$R"

# ── 4. Stale finalizer felülír-e egy újabb attemptet ────────────────────────
say "4. Régi futás finalizere az újabb attempt fölé ír-e"
R=$(mkfactory zeta)
launch "$R" zeta; P1=$LAUNCHED_PID
wait_ready "$R" 1 >/dev/null
kill -TERM "$P1" 2>/dev/null; wait "$P1" 2>/dev/null
echo "  az első futás SIGTERM-mel megölve; státusz: $(status_of "$R" zeta)"
bash "$CORE/meta-set.sh" "$R/repo/jobs/zeta/meta.yaml" 'status=running' 'lease_expires=2099-01-01T00:00:00Z'
echo "  szimulált ÚJABB attempt: status=running, friss lease"
touch "$R/go"; sleep 1
AFTER=$(status_of "$R" zeta)
echo "  a régi finalizer lefutása után: $AFTER"
if [[ "$AFTER" == "error" ]]; then
    verdict "REPRODUKÁLT — a régi futás finalizere error-ra írta az újabb attemptet"
else
    verdict "nem írta felül (státusz: $AFTER)"
fi
rm -rf "$R"

# ── 5. Push-verseny: non-fast-forward kezelése ──────────────────────────────
say "5. Push-verseny (két külön checkout, közös remote)"
R=$(mkfactory eta)
git clone -q "$R/remote.git" "$R/repo2"
git -C "$R/repo2" config user.email t@t; git -C "$R/repo2" config user.name t
mkdir -p "$R/nohooks2"; git -C "$R/repo2" config core.hooksPath "$R/nohooks2"
# a második checkout előrébb viszi a remote-ot
echo "idegen" > "$R/repo2/OTHER.txt"
git -C "$R/repo2" add -A >/dev/null; git -C "$R/repo2" commit -qm "másik checkout"
git -C "$R/repo2" push -q origin main
echo "  a remote előrement egy commit-tal"
launch "$R" eta; P1=$LAUNCHED_PID
wait_ready "$R" 1 >/dev/null; touch "$R/go"; wait "$P1" 2>/dev/null; rc=$?
echo "  a job futásának exit kódja: $rc"
echo "  helyi státusz: $(status_of "$R" eta)"
REMOTE_HAS=$(git -C "$R/repo" ls-remote origin main | cut -c1-8)
LOCAL_MAIN=$(git -C "$R/repo" rev-parse --short main)
echo "  remote main=$REMOTE_HAS  helyi main=$LOCAL_MAIN"
if [[ "$REMOTE_HAS" != "$LOCAL_MAIN" ]]; then
    verdict "REPRODUKÁLT — a lifecycle-állapot helyben marad, a remote nem tud róla"
    grep -hiE 'reject|non-fast-forward|failed to push|hiba' "$R"/eta*.log | head -3 | sed 's/^/     /'
else
    verdict "a push rendeződött (a remote és a helyi main egyezik)"
fi
rm -rf "$R"

# ── 6. Tud-e még írni egy megszüntetett futás? (#65) ────────────────────────
say "6. Megszüntetett futás késői írása (#65)"
R=$(mkfactory theta)
launch "$R" theta; SUBSHELL=$LAUNCHED_PID
wait_ready "$R" 1 >/dev/null
WRAPPER=$(wrapper_pid "$R" theta)
echo "  alhéj pid=$SUBSHELL   wrapper pid=${WRAPPER:-<nincs>}"
if [[ -z "$WRAPPER" ]]; then
    verdict "MÉRHETETLEN — nem találom a wrapper folyamatot"
else
    kill -TERM "$WRAPPER" 2>/dev/null
    sleep 1
    AFTER_KILL=$(status_of "$R" theta)
    echo "  a wrapper megölése után: $AFTER_KILL"
    # a runner-gyerek még blokkol; most engedjük el
    touch "$R/go"; sleep 1.5
    AFTER_GO=$(status_of "$R" theta)
    echo "  a runner elengedése után: $AFTER_GO"
    if [[ "$AFTER_KILL" != "$AFTER_GO" ]]; then
        verdict "REPRODUKÁLT — a megszüntetett futás utólag írt: $AFTER_KILL → $AFTER_GO"
    else
        verdict "nem írt utólag (a státusz végig '$AFTER_GO' maradt)"
    fi
    kill -TERM "$SUBSHELL" 2>/dev/null; wait "$SUBSHELL" 2>/dev/null
fi
rm -rf "$R"

# ── 7. A régi futás finalizere az újabb attempt fölé ír-e? (#65) ────────────
say "7. Régi finalizer az újabb attempt állapota fölé (#65)"
R=$(mkfactory iota)
launch "$R" iota; SUBSHELL=$LAUNCHED_PID
wait_ready "$R" 1 >/dev/null
WRAPPER=$(wrapper_pid "$R" iota)
if [[ -z "$WRAPPER" ]]; then
    verdict "MÉRHETETLEN — nem találom a wrapper folyamatot"
else
    # B attempt szimulálása: egy ÚJABB futás állítja be az állapotot
    bash "$CORE/meta-set.sh" "$R/repo/jobs/iota/meta.yaml" \
        'status=running' 'lease_expires=2099-01-01T00:00:00Z'
    echo "  szimulált B attempt: status=running, friss lease"
    # most öljük meg az A wrappert — a finalizere most fut le
    kill -TERM "$WRAPPER" 2>/dev/null; sleep 1.5
    AFTER=$(status_of "$R" iota)
    echo "  az A finalizerének lefutása után: $AFTER"
    if [[ "$AFTER" == "error" ]]; then
        verdict "REPRODUKÁLT — az A finalizere error-ra írta a B által beállított állapotot"
    else
        verdict "nem írta felül (a státusz '$AFTER')"
    fi
    touch "$R/go"; kill -TERM "$SUBSHELL" 2>/dev/null; wait "$SUBSHELL" 2>/dev/null
fi
rm -rf "$R"
