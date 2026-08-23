#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Futás-identitás (#41).
#
# A mért hiba: az A futás finalizere `error`-ra írta azt az állapotot, amit egy
# újabb B attempt állított be. Az őr `WE_SET_RUNNING && status == running` volt
# — mindkét fele teljesült, mert a `running` ugyanúgy néz ki, bárki írta.
#
# Most a meta `run_id` mezője mondja meg, melyik futás birtokolja a jobot, és a
# finalizer ehhez köti az írási jogosultságát.
#
# A finalizer eseteit a valódi prelude-dal futtatjuk, nem másolattal — ugyanúgy,
# ahogy a test-run-job-finalizer.sh teszi.

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

# ── teljes factory, valódi futásokhoz ──────────────────────────────────────
mkfactory() {   # <status>
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
    python3 - "$r" "${1:-pending}" <<'PY'
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
    local r="$1"; shift
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate "$@" </dev/null ) >"$r/run.log" 2>&1
    echo $?
}
field() { bash "$SRC/meta-get.sh" "$1/repo/jobs/t/meta.yaml" "$2" 2>/dev/null; }

echo "A running átmenet run_id-t és attempt-et ír"
R=$(mkfactory pending)
check "exit 0" "0" "$(run_job "$R")"
RID=$(field "$R" run_id)
check "  van run_id" "1" "$([ -n "$RID" ] && echo 1 || echo 0)"
check "  uuid alakú" "1" \
    "$(printf '%s' "$RID" | grep -cE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')"
check "  attempt 1" "1" "$(field "$R" attempt)"
check_log "  ki is írja" "run_id=$RID" "$R/run.log"
rm -rf "$R"

echo
echo "Az attempt minden újraindításnál lép"
R=$(mkfactory pending)
run_job "$R" >/dev/null
FIRST=$(field "$R" run_id)
run_job "$R" --force >/dev/null
SECOND=$(field "$R" run_id)
check "attempt 2" "2" "$(field "$R" attempt)"
check "  új run_id" "1" "$([ "$FIRST" != "$SECOND" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "Compare-and-swap: ha alattunk átállítják, nem indulunk"
# Nem lock — de megnevezi, ha valaki megelőzött, ahelyett hogy ráírna.
R=$(mkfactory pending)
cat > "$R/repo/tools/runners/echo.sh" <<'RUN'
#!/usr/bin/env bash
exit 0
RUN
# a spec-kapu és a runner-választás után, közvetlenül az írás előtt módosítunk:
# ezt a valódi futásban egy másik folyamat tenné
python3 - "$R/repo/tools/run-job.sh" <<'PY'
import sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
needle = 'STATUS_NOW=$(bash "$WORKDIR/tools/meta-get.sh" "$META" status 2>/dev/null) || STATUS_NOW=""'
s = s.replace(needle, 'bash "$WORKDIR/tools/meta-set.sh" "$META" "status=done"\n' + needle, 1)
open(p, "w", encoding="utf-8").write(s)
PY
check "elutasít" "1" "$(run_job "$R")"
check_log "  megnevezi a változást" "megváltozott alattunk" "$R/run.log"
check "  nem írt running-ot" "done" "$(field "$R" status)"
rm -rf "$R"

# ── finalizer, a valódi prelude-dal ────────────────────────────────────────
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tools" "$TMP/jobs"
cp "$SRC/meta-get.sh" "$SRC/meta-set.sh" "$SRC/update-index.sh" "$TMP/tools/"
PRELUDE_END=$(grep -n '^trap finalize EXIT INT TERM$' "$SRC/run-job.sh" | head -1 | cut -d: -f1)
sed -n "1,${PRELUDE_END}p" "$SRC/run-job.sh" > "$TMP/prelude.sh"

mkmeta() {   # <path> <status> <run_id>
    printf 'status: "%s"\nrun_id: "%s"\nerror_message: ""\ntimestamps:\n  created: "C"\n  started: "S"\n  completed: ""\n' \
        "$2" "$3" > "$1"
}
finalize_as() {   # <run_id a futásnak> <meta run_id>
    mkmeta "$TMP/meta.yaml" running "$2"
    cat > "$TMP/tools/case.sh" <<EOF
$(cat "$TMP/prelude.sh")
META="$TMP/meta.yaml"
RUN_LOG="$TMP/case.log"
RUN_ID="$1"
exit 7
EOF
    bash "$TMP/tools/case.sh" >/dev/null 2>"$TMP/case.err"
    bash "$SRC/meta-get.sh" "$TMP/meta.yaml" status
}

echo
echo "A finalizer csak a SAJÁT futását veheti vissza (#41)"
check "saját run_id → error" "error" "$(finalize_as "AAA" "AAA")"

echo
echo "  idegen run_id → nem nyúl hozzá"
check "a státusz running marad" "running" "$(finalize_as "AAA" "BBB")"
check_log "  megmondja, hogy átvették" "másik futás vette át" "$TMP/case.err"
check_log "  megnevezi mindkét azonosítót" "run_id=BBB" "$TMP/case.err"

echo
echo "  run_id nélküli meta (a mező bevezetése előtti futás) → nem nyúl hozzá"
# Fail closed: amiről nem tudjuk, kié, azt nem vesszük vissza.
check "a státusz running marad" "running" "$(finalize_as "AAA" "")"

echo
echo "A WE_SET_RUNNING eltűnt a kódból"
check "nincs értékadás rá" "0" \
    "$(grep -c '^WE_SET_RUNNING=' "$SRC/run-job.sh")"
check "  nincs feltétel rá" "0" \
    "$(grep -c '\$WE_SET_RUNNING' "$SRC/run-job.sh")"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
