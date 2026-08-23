#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# A lifecycle-commit csak a saját job path-jait viheti (#63).
#
# Mérve két job párhuzamos futtatásával: az egyik állapot-commitja a másik
# fájljait is magával vitte. A `git add` a megnevezett path-okat stage-eli, a
# `git commit` viszont pathspec nélkül MINDENT commitol, ami már ott van.
#
# Ez a suite NEM versenyhelyzetet épít: az idegen változást előre stage-eljük,
# és úgy futtatjuk a jobot. Ugyanazt méri, determinisztikusan — a versenyzős
# változat a tools/measure-concurrency.sh-ban van.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}

mkfactory() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo/tools/runners" "$r/repo/jobs/.schema" "$r/repo/jobs/t/output" \
             "$r/repo/jobs/masik" "$r/home/.claude-personal/agents/agent-01" "$r/nohooks"
    for f in "$SRC"/*.sh; do
        [[ "$(basename "$f")" == "env.sh" ]] && continue
        cp "$f" "$r/repo/tools/"
    done
    cp "$SRC"/runners/*.sh "$r/repo/tools/runners/"
    cp "$ROOT"/jobs/.schema/*.json "$ROOT"/jobs/.schema/meta.yaml "$r/repo/jobs/.schema/"
    printf '# T\n## Output\n`output/report.md`\n' > "$r/repo/jobs/t/input.md"
    printf '# masik\n' > "$r/repo/jobs/masik/input.md"
    python3 - "$r" <<'PY'
import sys, yaml
root = sys.argv[1]
tpl = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
class Q(str): pass
yaml.add_representer(Q, lambda dd, x: dd.represent_scalar("tag:yaml.org,2002:str", str(x), style='"'))
def q(o):
    if isinstance(o, dict): return {k: q(v) for k, v in o.items()}
    if isinstance(o, list): return [q(v) for v in o]
    if isinstance(o, str):  return Q(o)
    return o
for job, status in (("t", "pending"), ("masik", "pending")):
    d = dict(tpl)
    d["job_id"] = job; d["level"] = "repo"; d["status"] = status
    d["agent"] = dict(tpl["agent"]); d["agent"]["model"] = "echo-model"
    d["agent"]["config_dir"] = f"{root}/home/.claude-personal/agents/agent-01"
    d["workplace"] = dict(tpl["workplace"]); d["workplace"]["branch"] = f"feature/{job}"
    yaml.dump(q(d), open(f"{root}/repo/jobs/{job}/meta.yaml", "w", encoding="utf-8"),
              sort_keys=False, allow_unicode=True)
PY
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
run_job() {
    ( cd "$1/repo" && env HOME="$1/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate </dev/null ) >"$1/run.log" 2>&1
    echo $?
}
# Egy lifecycle-commit által ÉRINTETT path-ok.
touched() { git -C "$1/repo" show --name-only --format='' "$2"; }

echo "0. Zavartalan futás → csak a saját path-ok"
R=$(mkfactory)
check "exit 0" "0" "$(run_job "$R")"
RUNNING=$(git -C "$R/repo" log --format='%H %s' | awk '/job: t — running/{print $1; exit}')
check "  van running commit" "1" "$([ -n "$RUNNING" ] && echo 1 || echo 0)"
check "  csak jobs/t és az index" "0" \
    "$(touched "$R" "$RUNNING" | grep -vc '^jobs/t/\|^jobs/index.yaml$')"
rm -rf "$R"

echo
echo "Idegen job fájlja előre stage-elve (#63)"
# Pontosan az, ami párhuzamos futásnál magától megtörténik: valami más már
# odatett valamit az indexbe, mielőtt a mi commitunk lefut.
R=$(mkfactory)
bash "$SRC/meta-set.sh" "$R/repo/jobs/masik/meta.yaml" 'status=running'
git -C "$R/repo" add jobs/masik/meta.yaml
check "az idegen változás stage-elve" "1" \
    "$(git -C "$R/repo" diff --cached --name-only | grep -c '^jobs/masik/meta.yaml$')"
check "  a job lefut" "0" "$(run_job "$R")"
RUNNING=$(git -C "$R/repo" log --format='%H %s' | awk '/job: t — running/{print $1; exit}')
check "  a running commit NEM viszi a másik jobot" "0" \
    "$(touched "$R" "$RUNNING" | grep -c '^jobs/masik/')"
FINAL=$(git -C "$R/repo" log --format='%H %s' | awk '/job: t — awaiting_review/{print $1; exit}')
check "  a záró commit sem" "0" "$(touched "$R" "$FINAL" | grep -c '^jobs/masik/')"
check "  az idegen változás stage-elve MARADT" "1" \
    "$(git -C "$R/repo" diff --cached --name-only | grep -c '^jobs/masik/meta.yaml$')"
rm -rf "$R"

echo
echo "Idegen fájl a repó gyökerében, stage-elve"
R=$(mkfactory)
echo "valaki más munkája" > "$R/repo/IDEGEN.txt"
git -C "$R/repo" add IDEGEN.txt
check "a job lefut" "0" "$(run_job "$R")"
RUNNING=$(git -C "$R/repo" log --format='%H %s' | awk '/job: t — running/{print $1; exit}')
check "  a commit nem viszi magával" "0" "$(touched "$R" "$RUNNING" | grep -c '^IDEGEN.txt$')"
check "  a fájl stage-elve maradt" "1" \
    "$(git -C "$R/repo" diff --cached --name-only | grep -c '^IDEGEN.txt$')"
rm -rf "$R"

# A finalizer commitjának szűkítését NEM itt mérjük: a CIC_ECHO_EXIT a normál
# hibaágat járja, nem a finalizert, tehát az itteni eset a már szűkített
# commitot mérné, és a mutáció zölden hagyná. A finalizer saját git-fixture-je
# a test-run-job-finalizer.sh-ban van — ott mérjük.

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
