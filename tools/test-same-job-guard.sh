#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Az „ez a job már fut" őr (#66). Eddig egyáltalán nem volt rá teszt: hat mért
# futásban helyesen viselkedett, ami nem ugyanaz, mint hogy le van fedve.
#
# Amit a mérés (#41 komment) mutatott: az őr létezik és működik — de NEM lock.
# A státusz olvasása és a `running` kiírása között van ablak, amit semmi nem zár.
# Amit ez a suite mér, az a döntés, nem az atomicitás.
#
# A javítás lényege, hogy a nem-interaktív elutasítás VÉLETLEN volt: `read`
# lezárt stdin-en hibázik, az `ans` üres marad, és a job emiatt állt meg. Egy
# kiszámíthatatlan mellékhatásra támaszkodni ugyanaz a műfaj, mint a hookot
# policy-határnak nevezni.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}
check_log() {
    if grep -qF -- "$2" "$3"; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — nem található: '$2'"; ((fail++)); fi
}

mkfactory() {   # <status> [lease]
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo/tools/runners" "$r/repo/jobs/.schema" "$r/repo/jobs/t/output" \
             "$r/home/.claude-personal/agents/agent-01" "$r/nohooks"
    for f in "$SRC"/*.sh; do
        [[ "$(basename "$f")" == "env.sh" ]] && continue
        cp "$f" "$r/repo/tools/"
    done
    cp "$SRC"/runners/*.sh "$r/repo/tools/runners/"
    cp "$ROOT"/jobs/.schema/*.json "$ROOT"/jobs/.schema/meta.yaml "$r/repo/jobs/.schema/"
    printf '# T\n## Output\n`output/report.md`\n' > "$r/repo/jobs/t/input.md"
    python3 - "$r" "$1" <<'PY'
import sys, yaml
root, status = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
d["job_id"] = "t"; d["level"] = "repo"; d["status"] = status
d["agent"]["model"] = "echo-model"
d["agent"]["config_dir"] = f"{root}/home/.claude-personal/agents/agent-01"
d["workplace"]["branch"] = "feature/t"
class Q(str): pass
yaml.add_representer(Q, lambda dd, x: dd.represent_scalar("tag:yaml.org,2002:str", str(x), style='"'))
def q(o):
    if isinstance(o, dict): return {k: q(v) for k, v in o.items()}
    if isinstance(o, list): return [q(v) for v in o]
    if isinstance(o, str):  return Q(o)
    return o
yaml.dump(q(d), open(f"{root}/repo/jobs/t/meta.yaml", "w", encoding="utf-8"),
          sort_keys=False, allow_unicode=True)
PY
    [[ -n "${2:-}" ]] && bash "$SRC/meta-set.sh" "$r/repo/jobs/t/meta.yaml" "lease_expires=$2"
    git init -q --bare "$r/remote.git"
    git -C "$r/repo" init -q
    git -C "$r/repo" config user.email t@t; git -C "$r/repo" config user.name t
    git -C "$r/repo" config commit.gpgsign false
    git -C "$r/repo" config core.hooksPath "$r/nohooks"
    git -C "$r/repo" remote add origin "$r/remote.git"
    git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm init
    git -C "$r/repo" branch -M main; git -C "$r/repo" push -q -u origin main
    echo "$r"
}
run_job() {   # <root> [extra flag...]
    local r="$1"; shift
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate "$@" </dev/null ) >"$r/run.log" 2>&1
    echo $?
}
status_of() { bash "$SRC/meta-get.sh" "$1/repo/jobs/t/meta.yaml" status 2>/dev/null; }

PAST=$(date -u -d '-90 minutes' +"%Y-%m-%dT%H:%M:%SZ")
FUTURE=$(date -u -d '+90 minutes' +"%Y-%m-%dT%H:%M:%SZ")

echo "0. pending → az őr nem szól bele"
R=$(mkfactory pending)
check "exit 0" "0" "$(run_job "$R")"
check "  lefut" "awaiting_review" "$(status_of "$R")"
rm -rf "$R"

echo
echo "running + ÉLŐ lease → megáll, és megmondja hogy él"
R=$(mkfactory running "$FUTURE")
check "exit 1" "1" "$(run_job "$R")"
check_log "  élőnek nevezi" "ÉLŐ futás" "$R/run.log"
check_log "  kimondja, hogy nem tippel" "nem kérdezek, és nem tippelek" "$R/run.log"
check_log "  megmondja mi a teendő" "--force" "$R/run.log"
check "  a státusz érintetlen" "running" "$(status_of "$R")"
rm -rf "$R"

echo
echo "running + LEJÁRT lease → megáll, de más indoklással"
# Ugyanaz a mondat mindkettőre eddig sem volt jó: az élő futás elvétele és egy
# elakadt maradvány átvétele nem ugyanaz a döntés.
R=$(mkfactory running "$PAST")
check "exit 1" "1" "$(run_job "$R")"
check_log "  lejártnak nevezi" "lejárt" "$R/run.log"
check "  NEM mondja élőnek" "0" "$(grep -c 'ÉLŐ futás' "$R/run.log")"
check_log "  a stale-checkerhez irányít" "check-stale-jobs.sh" "$R/run.log"
rm -rf "$R"

echo
echo "running + lease NÉLKÜL → megáll, és kimondja hogy nem eldönthető"
R=$(mkfactory running)
check "exit 1" "1" "$(run_job "$R")"
check_log "  ezt mondja" "nem eldönthető" "$R/run.log"
rm -rf "$R"

echo
echo "running + értelmezhetetlen lease → megáll, és megnevezi az értéket"
R=$(mkfactory running "tegnap")
check "exit 1" "1" "$(run_job "$R")"
check_log "  megnevezi" "értelmezhetetlen: 'tegnap'" "$R/run.log"
rm -rf "$R"

echo
echo "--force → átveszi, és ezt ki is mondja"
R=$(mkfactory running "$FUTURE")
check "exit 0" "0" "$(run_job "$R" --force)"
check_log "  jelzi a felülírást" "a --force ezt felülírja" "$R/run.log"
check "  le is fut" "awaiting_review" "$(status_of "$R")"
rm -rf "$R"

echo
echo "awaiting_review és done → szintén megáll --force nélkül"
for st in awaiting_review done; do
    R=$(mkfactory "$st")
    check "$st → exit 1" "1" "$(run_job "$R")"
    check "  a státusz érintetlen" "$st" "$(status_of "$R")"
    rm -rf "$R"
done

echo
echo "  és --force-szal átmegy"
R=$(mkfactory done)
check "exit 0" "0" "$(run_job "$R" --force)"
check "  újrafutott" "awaiting_review" "$(status_of "$R")"
rm -rf "$R"

echo
echo "Sorvégi komment a status-on: az őr AKKOR IS tüzel"
# A #67-ig ezt a státuszt `running\" # agent-01`-ként olvasta egy regex, tehát
# az őr nem tüzelt volna — ugyanaz a bypass, amit a #29/#30 máshol lezárt.
R=$(mkfactory pending)
python3 - "$R/repo/jobs/t/meta.yaml" <<'PYZ'
import re, sys
p = sys.argv[1]; c = open(p, encoding="utf-8").read()
c = re.sub(r'^status:.*$', 'status: running # agent-01', c, flags=re.M)
open(p, "w", encoding="utf-8").write(c)
PYZ
check "exit 1" "1" "$(run_job "$R")"
check_log "  futóként ismerte fel" "Job már fut" "$R/run.log"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
