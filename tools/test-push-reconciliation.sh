#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# A remote a bizalom forrása: a `running` állapot azért megy ki az agent
# indulása ELŐTT, hogy egy halott wrapper ne tudjon eltitkolni egy futó jobot.
# Egy elutasított push ezt megtörte — a futás helyben maradt, a remote pedig azt
# mutatta, ami korábban volt (#64).
#
# A mérés (tools/measure-concurrency.sh) azt is megmutatta, hogy ehhez NEM kell
# két job: egy job plusz bármilyen más push a main-re elég, ami egyetlen
# orchestrátorral is megtörténik.

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

mkfactory() {
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
    python3 - "$r" <<'PY'
import sys, yaml
root = sys.argv[1]
d = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
d["job_id"] = "t"; d["level"] = "repo"; d["status"] = "pending"
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

# Egy MÁSIK checkout előreviszi a remote-ot — ehhez nem kell második job.
advance_remote() {
    local r="$1" what="${2:-idegen}"
    rm -rf "$r/other"
    git clone -q "$r/remote.git" "$r/other"
    git -C "$r/other" config user.email o@o; git -C "$r/other" config user.name o
    git -C "$r/other" config commit.gpgsign false
    mkdir -p "$r/nohooks2"; git -C "$r/other" config core.hooksPath "$r/nohooks2"
    printf '%s\n' "$what" > "$r/other/OTHER.txt"
    git -C "$r/other" add -A >/dev/null; git -C "$r/other" commit -qm "másik checkout"
    git -C "$r/other" push -q origin main
}
run_job() {
    local r="$1"
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate </dev/null ) >"$r/run.log" 2>&1
    echo $?
}
status_local()  { bash "$SRC/meta-get.sh" "$1/repo/jobs/t/meta.yaml" status 2>/dev/null; }
status_remote() {
    git -C "$1/repo" fetch -q origin main 2>/dev/null
    git -C "$1/repo" show origin/main:jobs/t/meta.yaml > "$1/rm.yaml" 2>/dev/null || { echo ""; return; }
    bash "$SRC/meta-get.sh" "$1/rm.yaml" status 2>/dev/null
}

echo "0. Zavartalan futás → a remote is látja"
R=$(mkfactory)
check "exit 0" "0" "$(run_job "$R")"
check "  helyi státusz" "awaiting_review" "$(status_local "$R")"
check "  a remote ugyanazt mondja" "awaiting_review" "$(status_remote "$R")"
rm -rf "$R"

echo
echo "A remote előrement közben — csak idegen path-on (#64)"
# Ez az eset, ami EGY orchestrátorral is megtörténik.
R=$(mkfactory); advance_remote "$R"
check "a job mégis lefut" "0" "$(run_job "$R")"
check "  helyi státusz" "awaiting_review" "$(status_local "$R")"
check "  ÉS a remote is látja" "awaiting_review" "$(status_remote "$R")"
check_log "  jelzi az egyeztetést" "A push elutasítva" "$R/run.log"
check_log "  és hogy sikerült" "Egyeztetve és kipusholva" "$R/run.log"
check "  az idegen commit megmaradt" "1" "$(git -C "$R/repo" log --oneline origin/main | grep -c 'másik checkout')"
rm -rf "$R"

echo
echo "A jobot alattunk átállították → nem egyeztetünk, megállunk"
# Ha a saját jobunk állapota változott a remoten, már nem mi birtokoljuk az
# átmenetet. A rebase csak elfedné.
R=$(mkfactory)
rm -rf "$R/other"; git clone -q "$R/remote.git" "$R/other"
git -C "$R/other" config user.email o@o; git -C "$R/other" config user.name o
git -C "$R/other" config commit.gpgsign false
mkdir -p "$R/nohooks2"; git -C "$R/other" config core.hooksPath "$R/nohooks2"
bash "$SRC/meta-set.sh" "$R/other/jobs/t/meta.yaml" 'status=done'
git -C "$R/other" add -A >/dev/null; git -C "$R/other" commit -qm "valaki más lezárta"
git -C "$R/other" push -q origin main
rc=$(run_job "$R")
check "a futás elbukik" "1" "$rc"
check_log "  megmondja, hogy átállították" "alattunk átállították" "$R/run.log"
check_log "  megnevezi a távoli állapotot" "a remote 'done'-t mond" "$R/run.log"
check "  a remote állapota érintetlen" "done" "$(status_remote "$R")"
rm -rf "$R"

echo
echo "A feature branch üzenete nem állíthat pusholást, ami nem történt meg"
# Az echo runner nem pushol feature branchet — nincs is mit. A régi üzenet
# ezt feltétel nélkül kimondta, tehát ÉPP az e2e úton hazudott, minden
# futásnál. Az őszinte kimenet itt a figyelmeztetés.
R=$(mkfactory)
run_job "$R" >/dev/null
check "a branch tényleg nincs a remoten" "0" \
    "$(git -C "$R/repo" ls-remote --heads origin feature/t | wc -l | tr -d ' ')"
check_log "  a wrapper ezt mondja, nem azt hogy pusholt" "NINCS a remoten" "$R/run.log"
check "  a hazug mondat nem hangzik el" "0" "$(grep -c 'Feature branch pusholt' "$R/run.log")"
rm -rf "$R"

echo
echo "  ha a branch OTT van, a pozitív üzenet szólal meg"
# A branchet a futás ELŐTT tesszük ki, hogy a záró üzenet biztosan lefusson --
# egy --resume-os utólagos próba korábban megállhatna, és akkor az eset semmit
# nem mérne (némán átmenne).
R=$(mkfactory)
git -C "$R/repo" push -q origin "HEAD:refs/heads/feature/t"
check "a branch ott van a remoten" "1" \
    "$(git -C "$R/repo" ls-remote --heads origin feature/t | wc -l | tr -d ' ')"
run_job "$R" >/dev/null
check_log "  a pozitív üzenet szólal meg" "Feature branch pusholt" "$R/run.log"
check "  a figyelmeztetés nem" "0" "$(grep -c 'NINCS a remoten' "$R/run.log")"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
