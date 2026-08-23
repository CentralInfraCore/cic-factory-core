#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# measure-executor-boundary.sh — a #42 (FC-05) állításainak mérése.
#
# NEM teszt-suite, és nem fut a kapuban. A célja ugyanaz, mint a #41 és a #43
# mérőinek: a tervezés MÉRT alapon álljon.
#
# A runner-szerződés (docs/RUNNER-CONTRACT.md) az executor INDÍTÁSÁT
# leválasztotta. A kérdés az, hogy mi maradt még Claude-specifikus a mag
# lifecycle-jában — és mi ennek a konkrét következménye.
#
# Futtatás:  bash tools/measure-executor-boundary.sh

set -uo pipefail
SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
say() { printf '\n\033[1m%s\033[0m\n' "$1"; }
verdict() { printf '  → %s\n' "$1"; }
mkfactory() {   # <agent-config legyen-e>
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo/tools/runners" "$r/repo/jobs/.schema" "$r/repo/jobs/t/output" "$r/nohooks"
    [[ "${1:-yes}" == "yes" ]] && mkdir -p "$r/home/.claude-personal/agents/agent-01"
    mkdir -p "$r/home"
    for f in "$SRC"/*.sh; do [[ "$(basename "$f")" == "env.sh" ]] && continue; cp "$f" "$r/repo/tools/"; done
    cp "$SRC"/runners/*.sh "$r/repo/tools/runners/"
    cp "$ROOT"/jobs/.schema/*.json "$ROOT"/jobs/.schema/meta.yaml "$r/repo/jobs/.schema/"
    printf '# T\n## Output\n`output/report.md`\n' > "$r/repo/jobs/t/input.md"
    python3 - "$r" <<'PY'
import sys, yaml
root = sys.argv[1]
d = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
d["job_id"]="t"; d["level"]="repo"; d["status"]="pending"
d["agent"]["model"]="echo-model"
d["agent"]["config_dir"]=f"{root}/home/.claude-personal/agents/agent-01"
d["workplace"]["branch"]="feature/t"
class Q(str): pass
yaml.add_representer(Q, lambda dd,x: dd.represent_scalar("tag:yaml.org,2002:str", str(x), style='"'))
def q(o):
    if isinstance(o,dict): return {k:q(v) for k,v in o.items()}
    if isinstance(o,list): return [q(v) for v in o]
    if isinstance(o,str):  return Q(o)
    return o
yaml.dump(q(d), open(f"{root}/repo/jobs/t/meta.yaml","w",encoding="utf-8"), sort_keys=False, allow_unicode=True)
PY
    git init -q --bare "$r/remote.git"; git -C "$r/repo" init -q
    git -C "$r/repo" config user.email t@t; git -C "$r/repo" config user.name t
    git -C "$r/repo" config commit.gpgsign false; git -C "$r/repo" config core.hooksPath "$r/nohooks"
    git -C "$r/repo" remote add origin "$r/remote.git"
    git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm init
    git -C "$r/repo" branch -M main; git -C "$r/repo" push -q -u origin main
    echo "$r"
}
run_job() { local r="$1"; shift
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate "$@" </dev/null ) >"$r/run.log" 2>&1; echo $?; }

say "1. Fut-e a mag Claude agent-config NÉLKÜL, echo runnerrel?"
R=$(mkfactory no)
rc=$(run_job "$R")
echo "  exit=$rc"
head -3 "$R/run.log" | sed 's/^/     /'
if [[ "$rc" -ne 0 ]] && grep -q 'Agent nem létezik' "$R/run.log"; then
    verdict "REPRODUKÁLT — a mag Claude-könyvtárat követel akkor is, ha nem Claude fut"
else
    verdict "lefutott Claude-config nélkül is"
fi
rm -rf "$R"

say "2. Resume-olható-e egy nem-Claude runner?"
R=$(mkfactory yes)
run_job "$R" >/dev/null
SID=$(bash "$SRC/meta-get.sh" "$R/repo/jobs/t/meta.yaml" agent.session_id 2>/dev/null)
echo "  az echo runner után agent.session_id = '${SID:-<üres>}'"
rc=$(run_job "$R" --resume)
echo "  --resume exit=$rc"
grep -m1 'ERROR' "$R/run.log" | sed 's/^/     /'
verdict "a resume Claude .jsonl-t vár; más runner nem folytatható"
rm -rf "$R"

say "3. Mit tud a mag a Claude lemez-elrendezéséről?"
grep -n 'claude-personal\|PROJECT_SLUG\|SESSION_DIR\|\.jsonl' "$SRC/run-job.sh" | sed 's/^/  /' | head -8
verdict "a runner-szerződés az INDÍTÁST választotta le, a session-kezelést nem"

say "4. Két job egy agent-configon: felszedheti-e egymás sessionjét?"
# A VALÓDI runnert méri, nem a kiválasztó logika másolatát. Az echo runner nem
# ad vissza session-azonosítót, tehát a fallback ág fut -- és előre elhelyezünk
# két .jsonl-t, mintha egy másik job is ezen a configon dolgozna.
R=$(mkfactory yes)
SD="$R/home/.claude-personal/agents/agent-01/projects/$(echo "$R/repo" | sed 's#[/_]#-#g')"
mkdir -p "$SD"
cat > "$R/repo/tools/runners/twosess.sh" <<RUN
#!/usr/bin/env bash
set -uo pipefail
mkdir -p "$SD"
touch "$SD/JOB-A-1111.jsonl"; sleep 0.05
touch "$SD/JOB-B-2222.jsonl"
python3 -c "
import json,sys
json.dump({'result':'kesz','models':'x','stop_reason':'end_turn'}, open(sys.argv[1],'w'))" "\$CIC_RESULT_JSON"
exit 0
RUN
chmod +x "$R/repo/tools/runners/twosess.sh"
( cd "$R/repo" && env HOME="$R/home" CIC_AGENT_RUNNER=twosess \
    bash tools/run-job.sh t agent-01 --skip-spec-gate </dev/null ) >"$R/two.log" 2>&1
PICKED=$(bash "$SRC/meta-get.sh" "$R/repo/jobs/t/meta.yaml" agent.session_id 2>/dev/null)
echo "  két session keletkezett a futás alatt"
echo "  a metába került session_id: '${PICKED:-<üres>}'"
if [[ -n "$PICKED" ]]; then
    verdict "REPRODUKÁLT — választott egyet, pedig nem tudhatta, melyik ezé a jobé"
else
    grep -m1 'session-jelölt' "$R/two.log" | sed 's/^/     /'
    verdict "nem tippelt — a session_id üres maradt, és megmondta miért"
fi
rm -rf "$R"

say "5. A context-monitor hook melyik debug-logot olvassa?"
# Az audit: "a monitor mindig a teljes közös CLAUDE_CONFIG_DIR/debug legújabb
# .txt fájlját olvassa" — két azonos configú job így egymás context-értékét
# láthatja. Ez a #27-tel NEM változott: az az állapotfájlokat vitte privát
# könyvtárba, a forrás kiválasztását nem.
if grep -q 'sort -rn | head -1' "$SRC/hooks/context-monitor.sh"; then
    grep -n -B2 'sort -rn | head -1' "$SRC/hooks/context-monitor.sh" | sed 's/^/  /'
    verdict "REPRODUKÁLT — a kiválasztás mtime szerint történik, job-kötés nélkül"
else
    verdict "nem mtime szerint választ"
fi
