#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Egy teljes job végigfuttatása: pending → running → awaiting_review → done.
#
# Ez eddig nem létezett, és a v0.1.0 release-notes „amit nem garantál" listájának
# az első tétele volt: minden kapu egy-egy döntést bizonyított külön-külön, azt
# senki, hogy a rendszer egyben működik.
#
# Az echo runner teszi lehetővé — agent, hálózat és költség nélkül. Ez az
# absztrakció első valódi haszna, nem mellékterméke.

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

# Teljes factory-fa: eszközök, séma, egy git repo távolival, agent config.
mkfactory() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo/tools/runners" "$r/repo/jobs/.schema" "$r/repo/jobs/t/output" \
             "$r/home/.claude-personal/agents/agent-01"
    # env.sh KIVÉVE: az a gép saját konfigja, gitignored, és a run-job.sh
    # sourceolja. Bemásolva a fixture nem hermetikus -- a futtató gépének
    # FACTORY_PROMPT_VARS és CIC_* értékei felülírnák azt, amit a teszt állít
    # be. A magban ez nem látszik (ott csak env.sh.example van); egy átvevő
    # repóban viszont minden ilyen eset elbukik.
    for f in "$SRC"/*.sh; do
        [[ "$(basename "$f")" == "env.sh" ]] && continue
        cp "$f" "$r/repo/tools/" 2>/dev/null
    done
    cp "$SRC"/runners/*.sh "$r/repo/tools/runners/"
    cp "$ROOT"/jobs/.schema/*.json "$ROOT"/jobs/.schema/meta.yaml "$r/repo/jobs/.schema/"

    cat > "$r/repo/jobs/t/input.md" <<'EOF'
# Teszt job

## Forrás
Olvasd el: /home/example/repo/docs/thing.md

## Tiltott rövidítések
- fájl létezése ≠ implemented

## Output
`output/report.md` — tartalmazza:

| Állítás | Státusz | Bizonyíték | Verifikációs módszer | Kockázat |
|---|---|---|---|---|
EOF
    python3 - "$r" <<'PY'
import sys, yaml
root = sys.argv[1]
d = yaml.safe_load(open(f"{root}/repo/jobs/.schema/meta.yaml", encoding="utf-8"))
d["job_id"] = "t"; d["level"] = "repo"; d["status"] = "pending"
d["agent"]["model"] = "echo-model"
d["agent"]["config_dir"] = f"{root}/home/.claude-personal/agents/agent-01"
d["workplace"]["branch"] = "feature/t"
# Csak az ÉRTÉKEK idézőjelesek, ahogy a valódi meták néznek ki. A default_style
# a kulcsokat is idézőjelezné, és akkor a `grep '^status:'` nem illeszkedne.
class Q(str): pass
yaml.add_representer(Q, lambda d, x: d.represent_scalar("tag:yaml.org,2002:str", str(x), style='"'))
def quote(o):
    if isinstance(o, dict):  return {k: quote(v) for k, v in o.items()}
    if isinstance(o, list):  return [quote(v) for v in o]
    if isinstance(o, str):   return Q(o)
    return o
yaml.dump(quote(d), open(f"{root}/repo/jobs/t/meta.yaml", "w", encoding="utf-8"),
          sort_keys=False, allow_unicode=True)
PY

    # A run-job.sh commitol és pushol, tehát kell egy távoli.
    git init -q --bare "$r/remote.git"
    git -C "$r/repo" init -q
    git -C "$r/repo" config user.email t@t
    git -C "$r/repo" config user.name t
    git -C "$r/repo" config commit.gpgsign false
    git -C "$r/repo" remote add origin "$r/remote.git"
    git -C "$r/repo" add -A
    git -C "$r/repo" commit -q -m init --no-verify
    git -C "$r/repo" branch -M main
    git -C "$r/repo" push -q -u origin main
    echo "$r"
}

status_of() { grep '^status:' "$1/repo/jobs/t/meta.yaml" | head -1 | awk -F'"' '{print $2}'; }
field()     { grep "^ *$2:" "$1/repo/jobs/t/meta.yaml" | head -1 | awk -F'"' '{print $2}'; }

run_job() {
    local r="$1"; shift
    ( cd "$r/repo" && HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 "$@" ) >"$r/run.log" 2>&1
    echo $?
}

echo "1. pending → awaiting_review, agent nélkül"
R=$(mkfactory)
RC=$(run_job "$R")
[[ "$RC" != "0" ]] && { echo "  --- run.log ---"; sed 's/^/      /' "$R/run.log" | tail -20; }
check "a run-job.sh lefut" "0" "$RC"
check "  a státusz awaiting_review" "awaiting_review" "$(status_of "$R")"
check "  NEM done" "1" "$([[ "$(status_of "$R")" != "done" ]] && echo 1 || echo 0)"
check "  spec_gate: passed" "passed" "$(field "$R" spec_gate)"
check_log "  a runner nevét kiírja" "Runner: echo" "$R/run.log"
[[ -s "$R/repo/jobs/t/workspace/cic-factory/jobs/t/output/agent-output.md" ]] \
    && { echo "  PASS  az agent kimenete fájlba került"; ((pass++)); } \
    || { echo "  FAIL  nincs agent-output.md"; ((fail++)); }

echo
echo "2. A lezárás elutasít, amíg nincs review"
CLOSE() { ( cd "$R/repo" && bash tools/close-job.sh t ) >"$R/close.log" 2>&1; echo $?; }
check "review nélkül elutasít" "1" "$(CLOSE)"
check "  a státusz változatlan" "awaiting_review" "$(status_of "$R")"

echo
echo "3. Output-kapu és review után lezárható"
# A spec említi az "implemented" szót, ezért az O4 reachability artifactot kér:
# file:line hívási pontot vagy deadcode kimenetet. Ez is a kapu helyes működése.
printf '# Riport\n| Állítás | Státusz | Bizonyíték | Verifikációs módszer | Kockázat |\n|---|---|---|---|---|\n| ok | igazolt | tools/run-job.sh:1 | újrafuttatható | alacsony |\n' \
    > "$R/repo/jobs/t/output/report.md"
# A review-nak meg kell neveznie a futást, amit nézett (C6, #43) — enélkül nem
# eldönthető, hogy ehhez az attempthez készült-e, vagy egy korábbihoz.
printf '# Review\nrun_id: %s\n## Amit ellenőriztem\n- a kapu zöld\n' \
    "$(field "$R" run_id)" > "$R/repo/jobs/t/review.md"
RC2=$(CLOSE)
[[ "$RC2" != "0" ]] && { echo "  --- close.log ---"; sed 's/^/      /' "$R/close.log" | tail -12; }
check "close-job.sh átmegy" "0" "$RC2"
check "  a státusz done" "done" "$(status_of "$R")"
check "  a lease törlődött" "" "$(field "$R" lease_expires)"
rm -rf "$R"

echo
echo "4. Nem-nulla exit → error, és nem awaiting_review"
R=$(mkfactory)
( cd "$R/repo" && HOME="$R/home" CIC_AGENT_RUNNER=echo CIC_ECHO_EXIT=3 \
    bash tools/run-job.sh t agent-01 ) >"$R/run.log" 2>&1
check "a státusz error" "error" "$(status_of "$R")"
rm -rf "$R"

echo
echo "5. A runner szerződésszegése nem bukatja el a jobot"
# Nem érvényes JSON: a nyers szöveg megmarad az embernek, a usage üres.
R=$(mkfactory)
( cd "$R/repo" && HOME="$R/home" CIC_AGENT_RUNNER=echo CIC_ECHO_GARBAGE=1 \
    bash tools/run-job.sh t agent-01 ) >"$R/run.log" 2>&1
check "a státusz awaiting_review" "awaiting_review" "$(status_of "$R")"
check_log "  jelzi, hogy nincs költség-adat" "nincs költség-adat" "$R/run.log"
grep -q 'this is not json' "$R/repo/jobs/t/workspace/cic-factory/jobs/t/output/agent-output.md" \
    && { echo "  PASS  a nyers kimenet megmaradt"; ((pass++)); } \
    || { echo "  FAIL  a nyers kimenet elveszett"; ((fail++)); }
rm -rf "$R"

echo
echo "6. Ismeretlen runner → érthető hiba, a job érintetlen"
R=$(mkfactory)
( cd "$R/repo" && HOME="$R/home" CIC_AGENT_RUNNER=nincsilyen \
    bash tools/run-job.sh t agent-01 ) >"$R/run.log" 2>&1
check "a job pending marad" "pending" "$(status_of "$R")"
check_log "  felsorolja a létezőket" "elérhető:" "$R/run.log"
rm -rf "$R"

echo
echo "==== $pass PASS / $fail FAIL ===="
[[ "$fail" -eq 0 ]]
