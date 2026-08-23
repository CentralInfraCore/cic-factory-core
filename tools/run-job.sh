#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
# Job lifecycle wrapper
# Használat: ./tools/run-job.sh <job-id> [agent-id] [--resume] [--skip-spec-gate] [--force]
#
#   --force
#       Egy már futó/lefutott job átvétele. Enélkül nem-interaktív
#       futásban a wrapper megáll, és megmondja, mit kell tenni.
#
#   --skip-spec-gate
#              Kihagyja a kötelező validate-spec.sh kaput. Csak akkor, ha
#              tudatosan iterálsz egy specen és tudod, hogy még NO-GO.
#              Nyomot hagy: a meta.yaml spec_gate mezőjébe "skipped" kerül,
#              hogy a review lássa, ez a futás kapu nélkül indult.
#
#   --resume   Session-limit/error miatt megszakadt futás folytatása
#              UGYANABBAN a Claude Code session-ben (claude --resume <session_id>).
#              A meglévő workspace-t és feature branch-et újrahasználja,
#              nem klónoz újra. Feltétel: meta.yaml agent.session_id ki van töltve
#              (az előző futás állította be).
#
# Job struktúra:
#   jobs/<job-id>/
#     input.md              ← orchestrátor definiálja
#     meta.yaml             ← lifecycle tracking
#     ref/                  ← referencia anyagok (opcionális, git-tracked)
#     workspace/            ← gitignored; agent klónjai élnek itt
#       cic-factory/        ← git clone, feature/<job-id> branch
#       <egyéb repo>/       ← ha a job más repót is igényel
set -euo pipefail

# Launching this through a pipe that closes early (`... | head -20`) used to send
# SIGPIPE mid-flight: the wrapper died on the signal, meta.yaml stayed "running"
# forever, and the agent carried on as an orphan with nobody left to record what
# it did.
#
# Ignoring PIPE does NOT keep the script alive — the next `echo` still fails with
# EPIPE and `set -e` ends the run (measured, not assumed). What it changes is the
# manner of death: an untrapped signal skips the EXIT trap, a `set -e` exit does
# not. So the finalizer below always gets to run, and the job is recorded as
# error instead of being left claiming "running".
trap '' PIPE

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"

# --- Finalizer -------------------------------------------------------------
# Runs on every exit path, including a failure under `set -e`, Ctrl-C, or a
# TERM. Its one job: never leave meta.yaml claiming "running" when nothing is
# running. It writes to a log file and to stderr rather than stdout, so it still
# works when stdout is the closed pipe that caused the exit in the first place.
FINALIZED=0
# Ennek a futásnak az azonosítója. A `running` átmenettel kerül a metába, és
# ehhez köti a finalizer az írási jogosultságát.
#
# Mérve (#41, measure-concurrency.sh 7. eset): enélkül az A futás finalizere
# `error`-ra írta azt az állapotot, amit egy újabb B attempt állított be. Az
# őr `WE_SET_RUNNING && status == running` volt -- mindkét fele teljesült,
# mert a `running` ugyanúgy néz ki, bárki írta.
RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
         || python3 -c 'import uuid; print(uuid.uuid4())')
AGENT_PID=""
RUN_LOG=""
finalize() {
    local rc=$?
    [[ "$FINALIZED" -eq 1 ]] && return
    FINALIZED=1
    trap - EXIT INT TERM

    # A normal run finalizes inline and sets FINALIZED itself; reaching here with
    # a still-"running" meta means the wrapper is dying early.
    #
    # Csak az a futás veheti vissza a jobot error-ba, amelyik a running
    # állapotot odaírta -- és ezt a meta run_id mezője mondja meg, nem egy
    # lokális boolean. A korábbi őr (`WE_SET_RUNNING && status == running`)
    # nem tudta megkülönböztetni egy újabb attempt running-ját a sajátjától,
    # és mérhetően felül is írta (#41).
    # A státusz itt jogosultsági döntés: eldönti, szabad-e visszavennünk a
    # jobot error-ba. Eddig `awk -F'"'` olvasta, ami egy sorvégi kommentnél
    # `running" # x`-et ad -- a finalizer ilyenkor némán nem javított. Ugyanaz
    # az osztály, mint #29/#30, csak itt a mulasztás a hiba.
    local st owner
    st=$(bash "$WORKDIR/tools/meta-get.sh" "${META:-/dev/null}" status 2>/dev/null) || st=""
    owner=$(bash "$WORKDIR/tools/meta-get.sh" "${META:-/dev/null}" run_id 2>/dev/null) || owner=""
    if [[ "$st" == "running" && -n "$owner" && "$owner" != "$RUN_ID" ]]; then
        echo "[!] A wrapper idő előtt kilépett (rc=$rc), de a jobot közben egy" >&2
        echo "    másik futás vette át (run_id=$owner, mienk=$RUN_ID)." >&2
        echo "    NEM írjuk error-ra: az az ő állapota, nem a miénk." >&2
        [[ $rc -eq 0 ]] && rc=1
        exit $rc
    fi
    if [[ "$st" == "running" && "$owner" == "$RUN_ID" ]]; then
        local end; end=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        # A lease a státusz javításával elveszti az értelmét; ott hagyva egy
        # már rendezett job elakadtnak látszana a check-stale-jobs.sh-nak.
        #
        # A `^(\s+)completed:` minta korábban MINDEN behúzott completed: sort
        # átírta, nem csak a timestamps alattit; az error_message-et pedig
        # behúzás-csoporttal kereste, holott top-level kulcs -- így a mező
        # minden hibánál üres maradt.
        bash "$WORKDIR/tools/meta-set.sh" "$META" \
            'status=error' \
            "timestamps.completed=$end" \
            'error_message=wrapper exited before finalizing — see the job log; the agent may have kept running' \
            'lease_expires=' || true
        {
            echo "[!] A wrapper idő előtt kilépett (rc=$rc). meta.yaml → error."
            [[ -n "$AGENT_PID" ]] && kill -0 "$AGENT_PID" 2>/dev/null && \
                echo "[!] Az agent MÉG FUT árván: PID $AGENT_PID — nézd meg, mielőtt újraindítasz."
            [[ -n "$RUN_LOG" ]] && echo "[*] Napló: $RUN_LOG"
        } >&2
        [[ -n "$RUN_LOG" ]] && {
            echo "wrapper exited early rc=$rc at $end; agent pid=${AGENT_PID:-none}"
        } >>"$RUN_LOG" 2>/dev/null || true

        # Best effort: the running state was pushed, so leaving the correction
        # local means the remote keeps claiming a job is running that is not.
        # This can legitimately fail -- no network, Vault down so the commit-msg
        # hook cannot sign, a protected branch -- and none of that may stop the
        # finalizer. It is loud instead, because a silent failure here is
        # precisely the stuck state it exists to prevent.
        #
        # The lease is the fallback: if this does not land, the deadline already
        # on the remote still makes the job detectably stuck.
        # Az index a normál úton a 304. és 663. sorban regenerálódik; a
        # finalizer egyiket sem járja be. Enélkül a javított meta MELLÉ a
        # futás előtti index kerül kipusholásra: meta=error, index=running.
        # A jobs/index.yaml az, amit a /job-boot és az ember tényleg olvas,
        # tehát a finalizer épp ott hagyta futónak a jobot, ahol számít.
        timeout 60 bash "$WORKDIR/tools/update-index.sh" >/dev/null 2>&1 \
            || echo "[!] Az index regenerálása nem sikerült — a commit a régi indexet viszi." >&2

        if timeout 60 git -C "$WORKDIR" add "$META" jobs/index.yaml 2>/dev/null \
           && timeout 60 git -C "$WORKDIR" commit -q -m "job: ${JOB_ID:-?} — error (wrapper exited early)" \
                  -- "$META" jobs/index.yaml 2>/dev/null \
           && timeout 60 git -C "$WORKDIR" push -q 2>/dev/null; then
            echo "[*] Az error állapot kipusholva — a remote nem mutat futó jobot." >&2
        else
            echo "[!] Az error állapotot NEM sikerült kipusholni. A remote még" >&2
            echo "    'running'-ot mutat — ezt kézzel kell rendezni:" >&2
            echo "      git -C $WORKDIR add ${META} jobs/index.yaml && git commit && git push" >&2
            echo "    A lease addig is lejár, tehát a tools/check-stale-jobs.sh látja." >&2
        fi
    fi
    [[ $rc -eq 0 ]] && rc=1
    exit $rc
}
trap finalize EXIT INT TERM

# Lokális path konfig betöltése (gitignored)
[[ -f "$WORKDIR/tools/env.sh" ]] && source "$WORKDIR/tools/env.sh"

# MCP config: explicit env var, vagy a cic-factory szülőkönyvtárából derive-olva
CIC_MCP_CONFIG="${CIC_MCP_CONFIG:-$(dirname "$WORKDIR")/.mcp.json}"

JOB_ID="${1:?Adj meg egy job-id-t, pl: poc-implementation-plan}"
shift

AGENT_ID="agent-01"
RESUME=0
SKIP_SPEC_GATE=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --resume) RESUME=1 ;;
        --skip-spec-gate) SKIP_SPEC_GATE=1 ;;
        --force) FORCE=1 ;;
        *) AGENT_ID="$arg" ;;
    esac
done

# Az azonosítókból path épül, és a path egyik vége egy `rm -rf`. Eddig semmi
# nem nézte meg az alakjukat: `../../evil` a workspace-gyökéren kívülre oldódott
# fel. A spec-kapu véletlenül útban volt (nem talált input.md-t), de az `--skip-
# spec-gate` elveszi, és egy validáló kapunak amúgy sem a fájlrendszer
# határainak őrzése a dolga. Ez itt fut, argumentum-feldolgozáskor, minden
# kapcsolótól függetlenül.
valid_id() {
    case "$2" in
        '') echo "[!] Üres $1." >&2; return 1 ;;
        -*) echo "[!] A $1 nem kezdődhet kötőjellel: '$2'" >&2; return 1 ;;
        .*) echo "[!] A $1 nem kezdődhet ponttal: '$2'" >&2; return 1 ;;
        *[!a-zA-Z0-9._-]*)
            echo "[!] A $1 csak [a-zA-Z0-9._-] karaktereket tartalmazhat: '$2'" >&2
            echo "    Ebből path épül, aminek a végén törlés van." >&2
            return 1 ;;
    esac
    return 0
}
valid_id "job-id" "$JOB_ID"     || exit 1
valid_id "agent-id" "$AGENT_ID" || exit 1

JOB_DIR="$WORKDIR/jobs/$JOB_ID"
META="$JOB_DIR/meta.yaml"
INPUT="$JOB_DIR/input.md"
WORKSPACE="$JOB_DIR/workspace"
FACTORY_CLONE="$WORKSPACE/cic-factory"
FEATURE_BRANCH="feature/$JOB_ID"
AGENT_CONFIG="$HOME/.claude-personal/agents/$AGENT_ID"
# Claude Code slugs a project path by replacing BOTH separators and underscores
# with dashes. Replacing only '/' silently produced a directory that does not
# exist for any path containing '_' — here /home/sinkog/sync/claude_factory/...
# resolved to ...-claude_factory-... instead of ...-claude-factory-..., which is
# why --resume could never find its session jsonl.
PROJECT_SLUG=$(echo "$WORKDIR" | sed 's#[/_]#-#g')
SESSION_DIR="$AGENT_CONFIG/projects/$PROJECT_SLUG"

# --- Ellenőrzések ---
[[ -f "$META" ]]  || { echo "[ERROR] Nem létezik: $META"; exit 1; }
[[ -f "$INPUT" ]] || { echo "[ERROR] Nem létezik: $INPUT"; exit 1; }
[[ -d "$AGENT_CONFIG" ]] || { echo "[ERROR] Agent nem létezik: $AGENT_CONFIG"; exit 1; }

# `set -o pipefail` mellett egy nem illeszkedő grep miatt ez a sor korábban
# ÜZENET NÉLKÜL megölte a scriptet: a finalizer lefutott, de nem szólt, mert még
# nem mi állítottuk running-ra. Egy hiányzó vagy szokatlan alakú status-sor így
# néma exit 1 volt.
# Ez az utolsó regexes státuszolvasó volt a fájlban: a #40 söprése kihagyta,
# mert nem Python-blokkban áll. Épp az „ez a job már fut" őrt táplálja, tehát
# egy `status: running # agent-01` sor mellett az őr NEM tüzelt volna --
# ugyanaz a bypass, amit a #29/#30 máshol lezárt.
STATUS=$(bash "$WORKDIR/tools/meta-get.sh" "$META" status 2>/dev/null) || STATUS=""
if [[ -z "$STATUS" ]]; then
    echo "[ERROR] Nem olvasható ki a status a $META-ból." >&2
    echo "        Várt alak a sor elején: status: \"pending\"" >&2
    exit 1
fi
MODEL=$(grep '^  model:' "$META" | awk -F'"' '{print $2}' || true)
SESSION_ID=$(grep '^\s*session_id:' "$META" | awk -F'"' '{print $2}' || true)
LEVEL=$(grep '^level:' "$META" | awk -F'"' '{print $2}' || true)

# --- meta.yaml extras: kb_focus + max_turns ---
# kb_focus is injected into the prompt as a mandatory first-read list (weak models
# are poor at discovery, good at execution — hand them the context).
# max_turns is a hard runaway guard; without it an agent can burn unbounded tokens.
# Az utolsó regexes meta-olvasó volt. A kb_focus mintája csak a dupla
# idézőjeles inline listát ismerte: a `[c781, n9]` és a `['c781']` alak üresen
# jött vissza, a blokk-lista elemeibe pedig a sorvégi komment is beleragadt --
# `c781 # fontos` került a promptba. A max_turns mintája nem volt szekcióhoz
# kötve, tehát a usage.max_turns-öt is felszedhette, ha az állt előrébb.
eval "$(python3 - "$META" <<'PYEOF'
import shlex
import sys

import yaml

doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}

focus = doc.get("kb_focus") or []
if isinstance(focus, str):
    focus = [focus]
focus = [str(x).strip() for x in focus if str(x).strip()]

turns = ((doc.get("agent") or {}).get("max_turns"))
turns = "" if turns is None else str(turns).strip()
if not turns.isdigit():
    turns = ""

print(f"KB_FOCUS={shlex.quote(' '.join(focus))}")
print(f"META_MAX_TURNS={shlex.quote(turns)}")
PYEOF
)"

# Level-based max_turns default when meta.yaml does not pin one
if [[ -n "$META_MAX_TURNS" ]]; then
    MAX_TURNS="$META_MAX_TURNS"
else
    case "$LEVEL" in
        domain)       MAX_TURNS=40 ;;
        repo)         MAX_TURNS=60 ;;
        orchestrator) MAX_TURNS=80 ;;
        *)            MAX_TURNS=60 ;;
    esac
fi

if [[ "$RESUME" -eq 1 ]]; then
    [[ -n "$SESSION_ID" ]] || { echo "[ERROR] meta.yaml agent.session_id üres — nincs mit resume-olni"; exit 1; }
    [[ -d "$FACTORY_CLONE" ]] || { echo "[ERROR] Nincs workspace: $FACTORY_CLONE — előbb futtasd a job-ot --resume nélkül"; exit 1; }
    [[ -f "$SESSION_DIR/$SESSION_ID.jsonl" ]] || { echo "[ERROR] Session jsonl nem található: $SESSION_DIR/$SESSION_ID.jsonl"; exit 1; }
else
    # Ez az őr NEM lock: a státusz olvasása és a `running` kiírása között van
    # ablak, amit semmi nem zár (#41). De a mérés (#66) szerint működik: hat
    # egyidejű indításból hatszor megállította a másodikat.
    #
    # Amit javítani kellett rajta: a nem-interaktív elutasítás VÉLETLEN volt.
    # `read` lezárt stdin-en hibával tér vissza, az `ans` üres marad, és a job
    # emiatt állt meg — nem azért, mert így döntöttünk. Egy automatizált
    # környezetben egy kiszámíthatatlan mellékhatásra támaszkodni ugyanaz a
    # műfaj, mint a hookot policy-határnak nevezni.
    guard() {   # <miért állunk meg> <mit tegyen, aki folytatni akarja>
        local why="$1" hint="$2"
        if [[ "$FORCE" -eq 1 ]]; then
            echo "[!] $why — a --force ezt felülírja. A futás folytatódik." >&2
            return 0
        fi
        echo "[!] $why" >&2
        if [[ ! -t 0 ]]; then
            echo "    Nem-interaktív futás: nem kérdezek, és nem tippelek." >&2
            echo "    $hint" >&2
            exit 1
        fi
        printf '    Folytatod? (y/N) ' >&2
        local ans=""; read -r ans || true
        [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
    }

    if [[ "$STATUS" == "running" ]]; then
        # A lease elmondja, hogy ez élő futás vagy egy elakadt maradványa.
        # A kettő nem ugyanaz a döntés, és eddig ugyanazt a mondatot kapták.
        lease=$(bash "$WORKDIR/tools/meta-get.sh" "$META" lease_expires 2>/dev/null) || lease=""
        if [[ -z "$lease" ]]; then
            detail="lease nélkül — nem eldönthető, él-e még"
        elif exp=$(date -u -d "$lease" +%s 2>/dev/null); then
            now=$(date -u +%s)
            if [[ "$now" -gt "$exp" ]]; then
                detail="a lease $(( (now - exp) / 60 )) perce lejárt — valószínűleg elakadt"
            else
                detail="ÉLŐ futás, a lease $(( (exp - now) / 60 )) perc múlva jár le"
            fi
        else
            detail="a lease értelmezhetetlen: '$lease'"
        fi
        guard "Job már fut ($detail)." \
              "Ha tényleg el akarod venni tőle: --force. Előbb nézd meg a tools/check-stale-jobs.sh kimenetét."
    fi
    if [[ "$STATUS" == "awaiting_review" ]]; then
        guard "Job lefutott, review-ra vár." \
              "Újrafuttatáshoz: --force. A korábbi review.md és output/ megmarad."
    fi
    if [[ "$STATUS" == "done" ]]; then
        guard "Job már kész." "Újrafuttatáshoz: --force."
    fi
fi

# --- runner kiválasztás ---
# Which agent runs the job is a runner's business, not this script's.
# Contract: docs/RUNNER-CONTRACT.md
#
# Ez a spec-kapuval együtt a pending → running ELŐTT fut: egy elgépelt runner-név
# ne fogyassza el a jobot és ne hagyjon running állapotot maga után.
AGENT_RUNNER="${CIC_AGENT_RUNNER:-claude}"
RUNNER_SCRIPT="$WORKDIR/tools/runners/$AGENT_RUNNER.sh"
if [[ ! -x "$RUNNER_SCRIPT" ]]; then
    echo "[ERROR] nincs ilyen runner: $RUNNER_SCRIPT" >&2
    echo "        elérhető: $(ls "$WORKDIR/tools/runners/" 2>/dev/null | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    exit 1
fi

# --- spec gate ---
# /job-run makes this mandatory and forbids starting an agent on NO-GO. The
# script used to skip it entirely, so the rule only held on the path nobody
# takes. It runs before pending → running, so a refusal leaves the job untouched.
#
# validate-spec.sh resolves jobs/<id>/ relative to the current directory, hence
# the subshell cd.
if [[ "$SKIP_SPEC_GATE" -eq 1 ]]; then
    echo "[WARN] --skip-spec-gate — a gépi spec-kapu KIHAGYVA. Ez a futás nem igazolt."
else
    if ! ( cd "$WORKDIR" && bash tools/validate-spec.sh "$JOB_ID" ); then
        echo "" >&2
        echo "[ERROR] A spec-kapu NO-GO-t adott — az agent nem indul." >&2
        echo "        Javítsd az input.md-t / meta.yaml-t, vagy ha tudatosan" >&2
        echo "        iterálsz egy még hiányos specen: --skip-spec-gate." >&2
        exit 1
    fi
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# A lease is a deadline, not a heartbeat. A heartbeat has to keep being written
# by a process that may already be gone; a deadline is written once, travels out
# with the running commit, and lets anyone reading the repo decide whether a job
# still claiming "running" is stuck -- without the dead process cooperating.
LEASE_HOURS="${CIC_JOB_LEASE_HOURS:-6}"
LEASE_EXPIRES=$(date -u -d "+${LEASE_HOURS} hours" +"%Y-%m-%dT%H:%M:%SZ")

# A remote a bizalom forrása: a `running` állapot azért megy ki a remote-ra az
# agent indulása ELŐTT, hogy egy halott wrapper ne tudjon eltitkolni egy futó
# jobot. Egy csendben elbukó push ezt megtöri -- a remote azt mutatja, ami
# korábban volt, és a lease sem ért ki.
#
# Mérve (2026-08-23, #64): két külön checkoutból a második push
# non-fast-forward hibával elutasításra kerül, a job `error` lesz, és a helyi
# main olyan lifecycle-állapottal marad előrébb, amiről a remote nem tud.
# Ehhez NEM kell két job: egy job plusz bármilyen más push a main-re elég.
#
# Az újrapróbálás önmagában nem lenne helyes. Előbb el kell dönteni, hogy MI
# birtokoljuk-e még az átmenetet, amit publikálni akarunk.
push_lifecycle() {   # <a job elvárt távoli státusza a push ELŐTT>
    local expect="$1" err="$WORKDIR/.push-err.$$"
    if git -C "$WORKDIR" push -q 2>"$err"; then rm -f "$err"; return 0; fi

    if ! grep -qiE 'rejected|non-fast-forward|fetch first' "$err"; then
        echo "[!] A push nem elutasítás miatt bukott el:" >&2
        sed 's/^/    /' "$err" >&2; rm -f "$err"; return 1
    fi
    echo "[*] A push elutasítva — a remote előrement. Egyeztetés..." >&2
    rm -f "$err"

    if ! git -C "$WORKDIR" fetch -q origin main; then
        echo "[!] A fetch sem sikerült; a lifecycle-állapot helyben maradt." >&2
        return 1
    fi

    # A saját jobunk állapota változott-e alattunk? Ha igen, már nem mi
    # birtokoljuk ezt az átmenetet, és a rebase csak elfedné.
    local remote_meta="$WORKDIR/.remote-meta.$$" remote_status=""
    if git -C "$WORKDIR" show "origin/main:jobs/$JOB_ID/meta.yaml" > "$remote_meta" 2>/dev/null; then
        remote_status=$(bash "$WORKDIR/tools/meta-get.sh" "$remote_meta" status 2>/dev/null) || remote_status=""
    fi
    rm -f "$remote_meta"

    if [[ -n "$remote_status" && "$remote_status" != "$expect" ]]; then
        echo "[!] A jobot alattunk átállították: a remote '$remote_status'-t mond," >&2
        echo "    mi '$expect'-re alapoztunk. Ezt az átmenetet már nem mi birtokoljuk." >&2
        echo "    A helyi commit megmarad; kézzel kell eldönteni, mi legyen vele." >&2
        return 1
    fi

    # Csak idegen path-ok mozdultak: a commitot újraalkotjuk a friss remote-ra.
    if ! git -C "$WORKDIR" rebase -q origin/main >/dev/null 2>&1; then
        git -C "$WORKDIR" rebase --abort >/dev/null 2>&1 || true
        echo "[!] A rebase nem ment automatikusan — ütköző változás a remote-on." >&2
        return 1
    fi
    if git -C "$WORKDIR" push -q; then
        echo "[*] Egyeztetve és kipusholva." >&2
        return 0
    fi
    echo "[!] A push a második kísérletre sem sikerült." >&2
    return 1
}

# A lifecycle-commit csak a saját job path-jait viheti.
#
# Mérve (2026-08-23, #63): két job párhuzamosan, és az egyik állapot-commitja
# a másik fájljait is magával vitte:
#
#   job: beta — running  →  jobs/alpha/meta.yaml
#
# A `git add` a megnevezett path-okat stage-eli, a `git commit` viszont
# pathspec nélkül MINDENT commitol, ami már stage-elve van -- akármit tett oda
# egy másik futás egy pillanattal korábban.
#
# Nem adatvesztés, hanem bizonyíték-szennyezés: a job done commitja már nem
# izolálja, mit csinált a job. A #44 proof-profilja egy kevert snapshotot
# igazolna.
commit_lifecycle() {   # <commit-üzenet>
    local msg="$1"
    # A pathspec a commitnál dönt, nem az indexnél: ami más futásból van
    # stage-elve, az stage-elve marad, de nem kerül BELE ebbe a commitba.
    git -C "$WORKDIR" commit -q -m "$msg" -- "$META" jobs/index.yaml
}

# --- pending → running ---
echo "[*] $JOB_ID — running ($NOW)"
# A `^\s+started:` és `^\s+completed:` minták nem voltak szekcióhoz kötve:
# minden azonos nevű behúzott mezőt átírtak, bárhol álltak. A lease és a
# spec_gate beszúrása pedig a status: sorra támaszkodott -- ha az hiányzott,
# egyik sem került be.
#
# A bypass nyomot kell hagyjon, különben lyuk ugyanabban a bizonyítéki láncban,
# amire ez a repó épül. Akkor is íródik, ha nem volt kihagyva: a mező hiánya
# így régi metát jelent, nem tiszta futást.
SPEC_GATE_VALUE=$([[ "$SKIP_SPEC_GATE" -eq 1 ]] && echo skipped || echo passed)

# Compare-and-swap, amennyire egy fájl fölött lehet: a státuszt közvetlenül az
# írás előtt újraolvassuk, és csak akkor írunk, ha még az, amire alapoztunk.
# Ez nem lock -- két folyamat között marad ablak --, de a #66-ban maradt
# olvasás-írás rést szűkíti, és megnevezi, ha valaki közben megelőzött.
STATUS_NOW=$(bash "$WORKDIR/tools/meta-get.sh" "$META" status 2>/dev/null) || STATUS_NOW=""
if [[ "$STATUS_NOW" != "$STATUS" ]]; then
    echo "[ERROR] A job állapota megváltozott alattunk: '$STATUS' → '$STATUS_NOW'." >&2
    echo "        Valaki megelőzött; ezt a futást nem indítjuk el." >&2
    exit 1
fi

PREV_ATTEMPT=$(bash "$WORKDIR/tools/meta-get.sh" "$META" attempt 2>/dev/null) || PREV_ATTEMPT=""
case "$PREV_ATTEMPT" in ''|*[!0-9]*) PREV_ATTEMPT=0 ;; esac
ATTEMPT=$((PREV_ATTEMPT + 1))

bash "$WORKDIR/tools/meta-set.sh" "$META" \
    'status=running' \
    "timestamps.started=$NOW" \
    'timestamps.completed=' \
    "lease_expires=$LEASE_EXPIRES" \
    "spec_gate=$SPEC_GATE_VALUE" \
    "run_id=$RUN_ID" \
    "attempt=$ATTEMPT"
echo "[*] run_id=$RUN_ID (attempt $ATTEMPT)"

bash "$WORKDIR/tools/update-index.sh"
git -C "$WORKDIR" add "$META" jobs/index.yaml
commit_lifecycle "job: $JOB_ID — running"
# A push ELŐTT a remote még a futás előtti állapotot mutatja a jobra.
push_lifecycle "$STATUS"

# Az input.md-t eddig egy csupasz `envsubst` futtatta, ami a wrapper TELJES
# környezetét behelyettesíti. Két külön baj:
#
#   szivárgás   amit az orchestrátor exportál, az nevesíthető input.md-ből és
#               bekerül a promptba, a transcriptbe és a logba. A cic-factory
#               relay-full-build job specje tartalmaz $VAULT_TOKEN-t.
#
#   rongálás    ami NINCS beállítva, azt üresre cseréli. A specekben szereplő
#               `{"$ref": ...}`, `$schema`, `${encoded}` így üres stringként
#               ért az agenthez -- egy JSON Schema kérdés szó szerint
#               "Van-e `` referencia?" alakban.
#
# Az envsubst SHELL-FORMAT argumentuma pontosan ezt oldja meg: csak a felsorolt
# neveket cseréli, minden mást szó szerint hagy. A helyettesítés ráadásul
# letakarított környezetben fut, tehát nem a formátumon múlik, mi maradhat ki.
#
# A mag a saját neveit ismeri. A telepítés a sajátjait a tools/env.sh-ban adja
# hozzá: FACTORY_PROMPT_VARS="CIC_RELAY_PATH CIC_SCHEMAS_PATH ..."
PROMPT_VARS_BASE="JOB_ID AGENT_ID WORKDIR FACTORY_CLONE FEATURE_BRANCH CIC_JOB_ID CIC_WORKDIR"

render_prompt() {
    local input="$1" v fmt="" ; local -a envargs=()
    for v in $PROMPT_VARS_BASE ${FACTORY_PROMPT_VARS:-}; do
        case "$v" in
            *[!A-Za-z0-9_]*|[0-9]*)
                echo "[WARN] FACTORY_PROMPT_VARS: '$v' nem érvényes változónév, kihagyva" >&2
                continue ;;
        esac
        case "$v" in
            *TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*)
                echo "[WARN] FACTORY_PROMPT_VARS: '$v' titoknak látszik, és a promptba fog kerülni." >&2 ;;
        esac
        fmt="$fmt \$$v"
        envargs+=("$v=${!v-}")
    done
    # Ami a specben szerepel, be VAN állítva a környezetben, de nincs az
    # allowlistán: majdnem biztosan elfelejtett FACTORY_PROMPT_VARS-bejegyzés.
    # A `$ref` és `$schema` a kódrészletekből nincs beállítva, tehát nem szól.
    local named missing=""
    named=$(grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*\}?' "$input" 2>/dev/null \
            | tr -d '${}' | sort -u || true)
    for v in $named; do
        case " $PROMPT_VARS_BASE ${FACTORY_PROMPT_VARS:-} " in *" $v "*) continue ;; esac
        [[ -n "${!v-}" ]] && missing+=" $v"
    done
    if [[ -n "$missing" ]]; then
        echo "[WARN] az input.md hivatkozik rájuk, be is vannak állítva, de nem" >&2
        echo "       engedélyezettek, tehát szó szerint maradnak:$missing" >&2
        echo "       Ha behelyettesítendők, vedd fel őket a FACTORY_PROMPT_VARS-ba" >&2
        echo "       (tools/env.sh) — lásd tools/env.sh.example." >&2
    fi

    env -i PATH="$PATH" "${envargs[@]}" envsubst "$fmt" < "$input"
}

# --- Workspace előkészítése ---
if [[ "$RESUME" -eq 1 ]]; then
    echo "[*] Resume — meglévő workspace újrahasználva: $FACTORY_CLONE"
    CURRENT_BRANCH=$(git -C "$FACTORY_CLONE" branch --show-current)
    [[ "$CURRENT_BRANCH" == "$FEATURE_BRANCH" ]] || echo "[WARN] Workspace branch ($CURRENT_BRANCH) != $FEATURE_BRANCH"
else
    echo "[*] Workspace: $FACTORY_CLONE"
    # Második öv az azonosító-ellenőrzés mellé: a törlendő utat feloldjuk, és
    # megnézzük, tényleg a jobs/ alatt van-e. Symlinket sem követünk.
    #
    # A containment-ágnak nincs megkülönböztető tesztje: valid_id mellett nem
    # állítható elő olyan bemenet, ami idáig eljut ÉS kivezet a fából. Backstop
    # arra az esetre, ha valid_id valaha meggyengül -- a symlink-ellenőrzést
    # viszont a test-run-job-boundaries.sh méri.
    JOBS_ROOT=$(cd "$WORKDIR/jobs" && pwd -P)
    WS_PARENT=$(cd "$(dirname "$WORKSPACE")" && pwd -P) || {
        echo "[!] A workspace szülőkönyvtára nem oldható fel: $WORKSPACE" >&2; exit 1; }
    WS_RESOLVED="$WS_PARENT/$(basename "$WORKSPACE")"
    case "$WS_RESOLVED" in
        "$JOBS_ROOT"/*) ;;
        *) echo "[!] A workspace a jobs/ gyökéren kívülre esik, nem törlöm:" >&2
           echo "    $WS_RESOLVED" >&2; exit 1 ;;
    esac
    if [[ -L "$WORKSPACE" ]]; then
        echo "[!] A workspace symlink, nem könyvtár. Nem törlöm rajta keresztül." >&2
        exit 1
    fi
    rm -rf "$WS_RESOLVED"
    mkdir -p "$WORKSPACE"
    # Az agent azt a repót klónozza, amelyikben a job él — nem egy beégetett
    # címet. Korábban itt a CIC factory GitHub-URL-je állt: a mag ismerte egy
    # konkrét telepítés nevét, és a futtatás hálózatot meg SSH-kulcsot igényelt.
    #
    # A feloldás itt történik és nem feljebb, mert eddig a pontig nincs rá
    # szükség: a spec-kapunak nem kell távoli, és nem is kérünk olyat, amit még
    # nem használunk.
    FACTORY_REMOTE="${CIC_FACTORY_REMOTE:-$(git -C "$WORKDIR" remote get-url origin 2>/dev/null || true)}"
    if [[ -z "$FACTORY_REMOTE" ]]; then
        echo "[ERROR] Nem állapítható meg, honnan klónozzon az agent." >&2
        echo "        A workdir-nek legyen 'origin' távolija, vagy add meg: CIC_FACTORY_REMOTE" >&2
        exit 1
    fi
    git clone "$FACTORY_REMOTE" "$FACTORY_CLONE"
    git -C "$FACTORY_CLONE" checkout -b "$FEATURE_BRANCH"
    echo "[*] Feature branch: $FEATURE_BRANCH"
fi

# --- kb_focus prompt block ---
KB_FOCUS_BLOCK=""
if [[ -n "$KB_FOCUS" ]]; then
    KB_FOCUS_LIST=""
    for node in $KB_FOCUS; do
        KB_FOCUS_LIST+="- \`$node\`"$'\n'
    done
    KB_FOCUS_BLOCK="
---
## Kötelező első olvasás — kb_focus

Mielőtt bármit írnál vagy állítanál, olvasd el ezeket a KB elemeket a \`cic-graph\` MCP-n:

$KB_FOCUS_LIST
Használd: \`get_chunk(\"<id>\")\` chunk-ra (c-előtag), \`get_node(\"<id>\")\` node-ra (n-előtag),
vagy \`focus_pack\` a teljes csomagra.

Ezek nem javaslatok — a job specje jelölte ki őket kiindulási pontnak.
Ha valamelyik nem létezik vagy üres, azt írd le az outputban. Ne találd ki a tartalmát.
"
fi

# --- Prompt összeállítása ---
if [[ "$RESUME" -eq 1 ]]; then
    PROMPT="A munkamenet korábban megszakadt (session limit vagy hiba), mielőtt a feladat
befejeződött volna. Ugyanebben a session-ben folytatod, a teljes korábbi kontextus
(input.md, eddigi kutatás, döntések) megvan.

Nézd át a workspace jelenlegi állapotát (\`git -C $FACTORY_CLONE status\`,
\`git -C $FACTORY_CLONE log --oneline -10\`) és az eredeti input.md
(\`$FACTORY_CLONE/jobs/$JOB_ID/input.md\`) Definition of Done listáját — azonosítsd
mi van már kész és mi maradt hátra, majd fejezd be a hátralévő munkát.

Push csak \`$FEATURE_BRANCH\` branch-re. Main-re NEM."
else
    PROMPT="$(render_prompt "$INPUT")
$KB_FOCUS_BLOCK
---
## Munkakörnyezet

cic-factory klón: \`$FACTORY_CLONE\`
Feature branch: \`$FEATURE_BRANCH\`

- Output dokumentumok: \`$FACTORY_CLONE/jobs/$JOB_ID/output/\`
- Sub-job specek (ha létrehozol): \`$FACTORY_CLONE/jobs/<sub-job-id>/input.md\` + \`meta.yaml\`
- Referencia anyagok: \`$FACTORY_CLONE/jobs/$JOB_ID/ref/\`
- Egyéb repó klónok: \`$WORKSPACE/<repo-neve>/\` (ne commitold)

A munka végén commitolj és pushol a feature branch-re:
\`\`\`bash
git -C $FACTORY_CLONE add jobs/$JOB_ID/output/ jobs/
git -C $FACTORY_CLONE commit -m \"job: $JOB_ID — output\"
git -C $FACTORY_CLONE push -u origin $FEATURE_BRANCH
\`\`\`

Push csak \`$FEATURE_BRANCH\` branch-re. Main-re NEM."
fi

# --- Agent futtatás ---
echo "[*] Agent indítása: $AGENT_ID"
echo "[*] Model: ${MODEL:-default}  |  max-turns: $MAX_TURNS"
[[ -n "$KB_FOCUS" ]] && echo "[*] kb_focus injektálva: $KB_FOCUS"
[[ "$AGENT_RUNNER" != "claude" ]] && echo "[*] Runner: $AGENT_RUNNER"
mkdir -p "$FACTORY_CLONE/jobs/$JOB_ID/output"
export CIC_JOB_ID="$JOB_ID"
export CIC_WORKDIR="$WORKDIR"

# Docker Compose derives its project name from the directory basename, and a
# workspace clone has the SAME basename as the orchestrator's live checkout of
# the same repo. Whichever container starts first owns the name, and every
# later `docker compose exec` from the other tree silently attaches to it.
#
# Measured 2026-08-07 (cic-module-oracle-cloud, then twice on cic-object-model):
# `make manifest-verify` passed against a broken manifest, `make manifest-update`
# reported "updated" and changed nothing, and `docs.link-check` went green on a
# file that did not exist in the tree being checked — all because /app was bound
# to a different clone. `docker compose run` is unaffected; only `exec` is.
#
# Giving each job its own project name removes the collision at the source. The
# orchestrator's live checkouts keep the default basename-derived name.
export COMPOSE_PROJECT_NAME="cicjob-$(echo "$JOB_ID" | tr '[:upper:]_' '[:lower:]-')"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUTPUT_FILE="$FACTORY_CLONE/jobs/$JOB_ID/output/agent-output.md"
[[ "$RESUME" -eq 1 ]] && OUTPUT_FILE="$FACTORY_CLONE/jobs/$JOB_ID/output/agent-output-resume-$STAMP.md"
RAW_JSON="$(mktemp)"
RUN_LOG="$RAW_JSON.stderr"   # what the finalizer points the human at

# Fallback marker: ha a JSON parse elszáll, a jsonl mtime-keresés még megmenti a session_id-t
SESSION_MARKER=$(mktemp)
sleep 1  # mtime-felbontás miatt biztosan a marker UTÁN íródjon az új jsonl

# Run the agent as a background child and wait for it, rather than in the
# foreground. Two reasons, both about the orphan case: the wrapper learns the
# agent's PID (a foreground child has none the shell can name), and a signal
# sent to the wrapper alone no longer takes the agent down with it. `wait`
# still yields the agent's exit status, so the normal path is unchanged.
# stdin is closed — a background job reading the terminal would take SIGTTIN.
set +e
# The prompt goes through a file: as an argument its length runs into a
# platform limit, and the prompt carries the whole job spec.
PROMPT_FILE="$(mktemp)"
printf '%s' "$PROMPT" > "$PROMPT_FILE"

CIC_PROMPT_FILE="$PROMPT_FILE" \
CIC_RESULT_JSON="$RAW_JSON" \
CIC_RUN_LOG="$RUN_LOG" \
CIC_AGENT_CONFIG="$AGENT_CONFIG" \
CIC_MODEL="$MODEL" \
CIC_MAX_TURNS="$MAX_TURNS" \
CIC_RESUME_SESSION="$([[ "$RESUME" -eq 1 ]] && echo "$SESSION_ID" || echo "")" \
CIC_MCP_CONFIG="$CIC_MCP_CONFIG" \
    bash "$RUNNER_SCRIPT" < /dev/null &
AGENT_PID=$!
wait "$AGENT_PID"
EXIT_CODE=$?
AGENT_PID=""   # reaped — nothing to warn about from here on
rm -f "$PROMPT_FILE"
set -e

# --- A runner normalizált eredményének kibontása ---
# Ami itt marad, az agent-független: a runner szerződése szerint minden runner
# ugyanezt a JSON-t írja (jobs/.schema/runner-result.schema.json). A Claude
# JSON-jának alakja a tools/runners/claude.sh dolga, nem ezé.
RUN_SESSION_ID=""; RUN_COST=""; RUN_TURNS=""; RUN_STOP_REASON=""
RUN_IN_TOKENS=""; RUN_OUT_TOKENS=""; RUN_CACHE_READ=""; RUN_CACHE_CREATE=""
RUN_TOTAL_IN=""; RUN_MODELS=""; RUN_DURATION_MS=""; RUN_JSON_OK="0"
eval "$(python3 - "$RAW_JSON" "$OUTPUT_FILE" <<'PYEOF'
import json, shlex, sys

raw_path, out_path = sys.argv[1], sys.argv[2]
raw = open(raw_path, encoding="utf-8", errors="replace").read()


def emit(**kw):
    for k, v in kw.items():
        print(f"{k}={shlex.quote('' if v is None else str(v))}")


try:
    data = json.loads(raw)
    if not isinstance(data, dict) or "result" not in data:
        raise ValueError("nem a runner-szerződés szerinti alak")
except Exception:
    # A runner megszegte a szerződést: nem érvényes eredményt írt. A nyers
    # tartalom megmarad az embernek, a job nem bukik el emiatt -- de a usage
    # blokk üres marad, mert nincs mire alapozni.
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(raw)
    emit(RUN_JSON_OK="0")
    sys.exit(0)

with open(out_path, "w", encoding="utf-8") as f:
    f.write(str(data.get("result", "")))

t = data.get("tokens") or {}


def tok(name):
    v = t.get(name)
    return None if v is None else int(v)


in_tok, out_tok = tok("input"), tok("output")
cache_read, cache_create = tok("cache_read"), tok("cache_creation")
total_in = None
if None not in (in_tok, cache_read, cache_create):
    total_in = in_tok + cache_read + cache_create

# Egy runner, ami nem mér költséget, üresen hagyja a mezőt. Nullát írni oda
# mérésnek látszana.
emit(
    RUN_SESSION_ID=data.get("session_id"),
    RUN_COST=data.get("cost_usd"),
    RUN_TURNS=data.get("turns"),
    RUN_STOP_REASON=data.get("stop_reason"),
    RUN_IN_TOKENS=in_tok,
    RUN_OUT_TOKENS=out_tok,
    RUN_CACHE_READ=cache_read,
    RUN_CACHE_CREATE=cache_create,
    RUN_TOTAL_IN=total_in,
    RUN_MODELS=data.get("models"),
    RUN_DURATION_MS=data.get("duration_ms"),
    RUN_JSON_OK="1",
)
PYEOF
)"

# stderr csak akkor kerül fájlba, ha nem üres
if [[ -s "$RAW_JSON.stderr" ]]; then
    cp "$RAW_JSON.stderr" "$FACTORY_CLONE/jobs/$JOB_ID/output/agent-stderr-$STAMP.log"
fi
rm -f "$RAW_JSON" "$RAW_JSON.stderr"

# --- Session UUID elmentése (resume-hoz) ---
if [[ -n "$RUN_SESSION_ID" ]]; then
    SESSION_ID="$RUN_SESSION_ID"
    echo "[*] Session UUID: $SESSION_ID (JSON)"
else
    NEW_SESSION_ID=$(find "$SESSION_DIR" -maxdepth 1 -name '*.jsonl' -newer "$SESSION_MARKER" 2>/dev/null \
        | xargs -r ls -t 2>/dev/null | head -1 | xargs -r basename -s .jsonl || true)
    if [[ -n "$NEW_SESSION_ID" ]]; then
        SESSION_ID="$NEW_SESSION_ID"
        echo "[*] Session UUID: $SESSION_ID (jsonl fallback)"
    else
        echo "[WARN] Session UUID nem állapítható meg — --resume nem fog működni"
    fi
fi
rm -f "$SESSION_MARKER"

if [[ "$RUN_JSON_OK" == "1" ]]; then
    echo "[*] Költség: ${RUN_COST:-n/a} USD | turns: ${RUN_TURNS:-n/a}/$MAX_TURNS | stop: ${RUN_STOP_REASON:-n/a}"
    echo "[*] Tokenek: ${RUN_TOTAL_IN:-?} bemenet összesen (${RUN_IN_TOKENS:-?} friss + ${RUN_CACHE_READ:-?} cache-olvasás + ${RUN_CACHE_CREATE:-?} cache-írás) / ${RUN_OUT_TOKENS:-?} kimenet"
    [[ -n "$RUN_MODELS" ]] && echo "[*] Modellek: $RUN_MODELS"
else
    echo "[WARN] Az agent kimenete nem JSON — nyers szöveg az output fájlban, nincs költség-adat"
fi

END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Exit 0 means the agent finished, not that its output is acceptable. This script
# runs no output gate and produces no review artifact, so it has no basis for
# claiming "done" -- that transition belongs to the orchestrator, after
# validate-output.sh passes and review.md exists. See /job-close.
NEW_STATUS=$([[ $EXIT_CODE -eq 0 ]] && echo "awaiting_review" || echo "error")
echo "[$([ "$NEW_STATUS" = "awaiting_review" ] && echo "✓" || echo "!")] $JOB_ID — $NEW_STATUS ($END)"
# `[[ ... ]] && echo` would return 1 under `set -e` whenever the condition is
# false -- i.e. it would kill the script on exactly the error path.
if [[ "$NEW_STATUS" == "awaiting_review" ]]; then
    echo "[*] Következő lépés: /job-close $JOB_ID — output-kapu + review.md, az zárja done-ra"
fi

# --- running → awaiting_review/error + usage (live meta) ---
# Ez a blokk SZÁMOL, nem ír: a mezőket kulcs=érték párokként adja tovább, a
# fájlt a meta-set.sh szerkeszti. A korábbi verzió maga írt, és a mintái nem
# voltak szekcióhoz kötve: a `^\s+completed:` minden behúzott completed: sort
# átírta, a session_id az első `model:` alá került akárhol volt, a prev()
# pedig bármelyik szekció azonos nevű mezőjét felszedte. A usage-blokk cseréje
# az első üres sorig tartott, tehát a mögötte maradt régi mezők duplikált
# YAML-kulcsként éltek tovább.
mapfile -t META_ASSIGNMENTS < <(python3 - "$META" "$NEW_STATUS" "$END" "$SESSION_ID" \
         "$RUN_COST" "$RUN_TURNS" "$RUN_IN_TOKENS" "$RUN_OUT_TOKENS" "$RUN_DURATION_MS" "$MAX_TURNS" \
         "$RUN_CACHE_READ" "$RUN_CACHE_CREATE" "$RUN_TOTAL_IN" "$RUN_MODELS" "$RUN_STOP_REASON" "$RESUME" <<'PYEOF'
import sys

import yaml

(meta_path, status, end, session_id,
 cost, turns, in_tok, out_tok, duration_ms, max_turns,
 cache_read, cache_create, total_in, models, stop_reason, resume) = sys.argv[1:17]

doc = yaml.safe_load(open(meta_path, encoding="utf-8")) or {}
usage = doc.get("usage") or {}

# usage block — cost visibility per job (P3).
# Token fields are aggregated across ALL models the run used (main + auxiliary),
# from `modelUsage`. Read total_input_tokens, not input_tokens: the latter is
# only the UNCACHED share and is near-zero on a cached run.
#
# On --resume the block is SUMMED into, not overwritten. A resumed job is one
# job that ran in several pieces, and the cost of the job is the cost of all of
# them. Overwriting lost the first run entirely: measured 2026-08-07 on
# cic-object-model-spec, where a 12-turn $4.95 resume erased the 107-turn $12.06
# run that preceded it, and jobs/index.yaml then under-reported the job by 71%.
#
# Latest-wins fields (they describe the final run, not the total): stop_reason,
# max_turns. Models are unioned. `runs` makes the aggregate visible as such.
def prev(field, default="0"):
    """A KORÁBBI usage-érték, a usage szekcióból. A régi regex bármelyik
    szekció azonos nevű mezőjét felszedte."""
    value = usage.get(field)
    if value is None or str(value).strip() == "":
        return default
    return str(value)


def add_int(field, run_value):
    try:
        return str(int(prev(field)) + int(run_value or 0))
    except ValueError:
        return str(run_value or 0)


def add_float(field, run_value):
    try:
        return repr(float(prev(field)) + float(run_value or 0))
    except ValueError:
        return str(run_value or 0)


if resume == "1":
    runs         = add_int("runs", 1) if "runs" in usage else "2"
    cost         = add_float("cost_usd", cost)
    turns        = add_int("turns", turns)
    duration_ms  = add_int("duration_ms", duration_ms)
    in_tok       = add_int("input_tokens", in_tok)
    out_tok      = add_int("output_tokens", out_tok)
    cache_read   = add_int("cache_read_input_tokens", cache_read)
    cache_create = add_int("cache_creation_input_tokens", cache_create)
    total_in     = add_int("total_input_tokens", total_in)
    models = ",".join(sorted(set(filter(
        None, prev("models", "").split(",") + models.split(",")))))
else:
    runs = "1"

# A lease a futás végén értelmét veszti; ott hagyva egy befejezett job
# elakadtnak látszana.
# A run_id a futás végén is bent marad: megmondja, MELYIK kísérlet hagyta ott
# ezt az állapotot. A lease az, ami elveszti az értelmét.
out = [("status", status),
       ("lease_expires", ""),
       ("timestamps.completed", end)]
if session_id:
    out.append(("agent.session_id", session_id))
out += [("usage.runs", runs),
        ("usage.cost_usd", cost),
        ("usage.turns", turns),
        ("usage.max_turns", max_turns),
        ("usage.stop_reason", stop_reason),
        ("usage.duration_ms", duration_ms),
        ("usage.models", models),
        ("usage.total_input_tokens", total_in),
        ("usage.input_tokens", in_tok),
        ("usage.cache_read_input_tokens", cache_read),
        ("usage.cache_creation_input_tokens", cache_create),
        ("usage.output_tokens", out_tok)]

for key, value in out:
    print(f"{key}={value}")
PYEOF
)
bash "$WORKDIR/tools/meta-set.sh" "$META" "${META_ASSIGNMENTS[@]}"

bash "$WORKDIR/tools/update-index.sh"
git -C "$WORKDIR" add "$META" jobs/index.yaml
commit_lifecycle "job: $JOB_ID — $NEW_STATUS"
# Ekkor a remote azt kell mutassa, amit mi tettünk ki: running.
push_lifecycle "running"

FINALIZED=1   # the normal path recorded the status itself; the trap must not override it
echo "[✓] Kész: $JOB_ID — $NEW_STATUS"
# Ezt eddig feltétel nélkül kiírta. Ha a push nem ment át, a mondat hamis volt,
# és épp akkor, amikor a legfontosabb lett volna tudni róla.
if git -C "$FACTORY_CLONE" ls-remote --exit-code --heads origin "$FEATURE_BRANCH" >/dev/null 2>&1; then
    echo "[*] Feature branch pusholt: $FEATURE_BRANCH"
else
    echo "[!] A feature branch NINCS a remoten: $FEATURE_BRANCH" >&2
    echo "    Az agent munkája csak helyben van meg: $FACTORY_CLONE" >&2
fi
echo "[*] Review: gh pr create --head $FEATURE_BRANCH"
if [[ "$NEW_STATUS" == "error" ]]; then
    echo "[*] Folytatás ugyanebben a session-ben: ./tools/run-job.sh $JOB_ID $AGENT_ID --resume"
fi
