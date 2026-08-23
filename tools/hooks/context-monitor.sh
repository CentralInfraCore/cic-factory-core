#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 yurukusa
# Modifications: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
# Full licence text: LICENSES/MIT-yurukusa.txt
# context-monitor.sh — Context window capacity monitor for CIC agents.
# Source: https://github.com/yurukusa/claude-code-hooks/blob/main/hooks/context-monitor.sh (MIT)
# Adapted for CIC: job-specific state files, output path → jobs/<job-id>/output/context-state.md,
#   multi-agent config dir support, CIC evacuation template.
#
# Trigger: PostToolUse (all tools)
# Matcher: "" (every tool invocation)
#
# Graduated warnings: CAUTION(40%) → WARNING(25%) → CRITICAL(20%) → EMERGENCY(15%)
# At CRITICAL/EMERGENCY: writes evacuation template to jobs/<job-id>/output/context-state.md
#
# No-ops silently if CIC_JOB_ID or CIC_WORKDIR is unset.
# Always exits 0 — never blocks the agent.

[ -z "${CIC_JOB_ID:-}" ] && exit 0
[ -z "${CIC_WORKDIR:-}" ] && exit 0

# The state used to live in /tmp under a name derived from the job id, which is
# public -- it is in jobs/index.yaml. Any local process could create the file
# first, and the counter goes straight into $(( )), where bash expands command
# substitutions found inside the value. A counter containing x[$(cmd)] ran cmd.
# The same held for the evacuation cooldown timestamp, and `>` followed a
# symlink, so a pre-created link wrote wherever it pointed.
#
# A private 0700 directory closes all of that: nobody else can put a file there.
# It does NOT separate two concurrent runs of the same job -- they still share
# these files. That needs a run identity, which does not exist yet (#41).
state_dir() {
    local base
    if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "${XDG_RUNTIME_DIR}" ]; then
        base="${XDG_RUNTIME_DIR}/cic"
    else
        # No XDG_RUNTIME_DIR under cron, ssh without a session, or some
        # containers. $HOME/.cache is private to the user just the same.
        base="${HOME:-/tmp}/.cache/cic"
    fi
    mkdir -p "${base}/ctx" 2>/dev/null || return 1
    chmod 700 "$base" "${base}/ctx" 2>/dev/null
    printf '%s\n' "${base}/ctx"
}

STATE_DIR=$(state_dir) || exit 0
[ -z "$STATE_DIR" ] && exit 0

STATE_FILE="${STATE_DIR}/state-${CIC_JOB_ID}"
PCT_FILE="${STATE_DIR}/pct-${CIC_JOB_ID}"
COUNTER_FILE="${STATE_DIR}/count-${CIC_JOB_ID}"
EVAC_COOLDOWN_FILE="${STATE_DIR}/evac-${CIC_JOB_ID}"
EVAC_COOLDOWN_SEC=1800

MISSION_FILE="${CIC_WORKDIR}/jobs/${CIC_JOB_ID}/output/context-state.md"

# Never write through a symlink. The directory is ours, so this is belt and
# braces -- but a stale link from an older version costs nothing to drop.
write_state() {
    [ -L "$1" ] && rm -f "$1"
    printf '%s\n' "$2" > "$1" 2>/dev/null
}

# Read a value that is about to be used as a number. Anything that is not a
# plain non-negative integer becomes the default, and never reaches $(( )).
read_uint() {
    local file="$1" default="$2" value
    if [ -L "$file" ] || [ ! -f "$file" ]; then
        printf '%s\n' "$default"
        return
    fi
    value=$(cat "$file" 2>/dev/null)
    case "$value" in
        ''|*[!0-9]*) printf '%s\n' "$default" ;;
        *)           printf '%s\n' "$value" ;;
    esac
}

COUNT=$(read_uint "$COUNTER_FILE" 0)
COUNT=$((COUNT + 1))
write_state "$COUNTER_FILE" "$COUNT"

LAST_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "normal")

# Check every 3rd invocation; always check at CRITICAL/EMERGENCY
if [ $((COUNT % 3)) -ne 0 ] && [ "$LAST_STATE" != "critical" ] && [ "$LAST_STATE" != "emergency" ]; then
    exit 0
fi

# Extract context % from Claude Code debug logs.
# Checks both default and agent-specific config dirs.
get_context_pct() {
    local debug_dir
    for candidate in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.claude"; do
        [ -z "$candidate" ] && continue
        debug_dir="${candidate}/debug"
        [ -d "$debug_dir" ] || continue

        # A forrás kiválasztása eddig tisztán mtime szerint ment: a debug
        # könyvtár legfrissebb .txt-je, job-kötés nélkül. Két azonos
        # agent-configon futó job így EGYMÁS context-értékét olvashatta, és a
        # rossz job kaphatott CRITICAL/EMERGENCY figyelmeztetést (#42).
        #
        # A #27 az állapotfájlokat vitte privát könyvtárba; a forrást nem
        # érintette.
        #
        # Nem tippelünk okosabban: ha több fájl is friss, a forrás nem
        # egyértelmű, és inkább nincs százalék, mint egy másik jobé. A
        # tool-hívás-alapú becslés amúgy is ott van fallbackként.
        local latest fresh_count
        fresh_count=$(find "$debug_dir" -maxdepth 1 -name '*.txt' \
                      -newermt '-10 minutes' 2>/dev/null | wc -l)
        if [ "$fresh_count" -gt 1 ]; then
            # Egy üzenet hívásonként: a ciklus két jelöltet néz meg
            # (CLAUDE_CONFIG_DIR és ~/.claude), és mindkettőn szólva duplázna.
            # A gyakoriságot amúgy is a minden-harmadik-hívás kapu fogja.
            # STDERR: a függvény kimenetét `CONTEXT_PCT=$(get_context_pct)`
            # fogja fel, tehát a stdout-ra írt üzenet a SZÁZALÉK helyére kerülne.
            echo "CONTEXT [CIC]: $fresh_count friss debug-log ebben az agent-configban —" >&2
            echo "  nem eldönthető, melyik ezé a jobé. A context-százalék becsült." >&2
            return
        fi
        latest=$(find "$debug_dir" -maxdepth 1 -name '*.txt' -printf '%T@ %p\n' 2>/dev/null \
                 | sort -rn | head -1 | cut -d' ' -f2-)
        [ -z "$latest" ] && continue

        local line tokens window
        line=$(grep 'autocompact:' "$latest" 2>/dev/null | tail -1)
        [ -z "$line" ] && continue

        # sed returns the line UNCHANGED when the pattern does not match, so a
        # log line carrying no `tokens=` used to put its whole content here --
        # and from there into $(( )). Match first, extract second, and let
        # nothing through that is not a plain integer.
        tokens=$(expr "$line" : '.*tokens=\([0-9][0-9]*\)' 2>/dev/null)
        window=$(expr "$line" : '.*effectiveWindow=\([0-9][0-9]*\)' 2>/dev/null)

        case "$tokens" in ''|*[!0-9]*) continue ;; esac
        case "$window" in ''|*[!0-9]*) continue ;; esac
        [ "$window" -gt 0 ] || continue

        echo $(( (window - tokens) * 100 / window ))
        return
    done
    echo ""
}

CONTEXT_PCT=$(get_context_pct)

# Fallback: tool-call-count estimate (~180 calls ≈ 100% context)
if [ -z "$CONTEXT_PCT" ]; then
    CONTEXT_PCT=$(( 100 - (COUNT * 100 / 180) ))
    [ "$CONTEXT_PCT" -lt 0 ] && CONTEXT_PCT=0
    SOURCE="estimate"
else
    SOURCE="debug"
fi

write_state "$PCT_FILE" "$CONTEXT_PCT"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M')

generate_evacuation_template() {
    local level="$1"

    local last_ts now_ts
    last_ts=$(read_uint "$EVAC_COOLDOWN_FILE" 0)
    now_ts=$(date +%s)
    [ "$last_ts" -gt 0 ] && [ $(( now_ts - last_ts )) -lt "$EVAC_COOLDOWN_SEC" ] && return

    # Skip if an unfilled template already exists
    if [ -f "$MISSION_FILE" ] && grep -q '\[TODO\]' "$MISSION_FILE" 2>/dev/null; then
        return
    fi

    write_state "$EVAC_COOLDOWN_FILE" "$(date +%s)"
    mkdir -p "$(dirname "$MISSION_FILE")"

    cat >> "$MISSION_FILE" << EVAC_EOF

## Context Evacuation (${level} — ${TIMESTAMP})
<!-- Auto-generated by context-monitor.sh. Fill before /compact. -->

### Job state
- Job ID: ${CIC_JOB_ID}
- Feature branch: feature/${CIC_JOB_ID}
- Current task: [TODO]
- Progress: [TODO]
- Files being edited: [TODO]

### Git state
- Uncommitted changes: [TODO]
- Last commit: [TODO]

### Next action after /compact
- [TODO]

### Handoff
- Commit output/ with: git -C ${CIC_WORKDIR}/jobs/${CIC_JOB_ID}/workspace/cic-factory commit -m "job: ${CIC_JOB_ID} — partial"
EVAC_EOF
}

if [ "$CONTEXT_PCT" -le 15 ]; then
    if [ "$LAST_STATE" != "emergency" ]; then
        write_state "$STATE_FILE" "emergency"
        generate_evacuation_template "EMERGENCY"
    fi
    echo ""
    echo "EMERGENCY [CIC]: Context remaining ${CONTEXT_PCT}% (${SOURCE}) — job: ${CIC_JOB_ID}"
    echo "1. Commit all output/ changes immediately"
    echo "2. Run /compact"
    echo "3. Resume from context-state.md: ${MISSION_FILE}"
    echo "No further work. Commit and compact only."

elif [ "$CONTEXT_PCT" -le 20 ]; then
    if [ "$LAST_STATE" != "critical" ]; then
        write_state "$STATE_FILE" "critical"
        generate_evacuation_template "CRITICAL"
    fi
    echo ""
    echo "CRITICAL [CIC]: Context remaining ${CONTEXT_PCT}% (${SOURCE}) — job: ${CIC_JOB_ID}"
    echo "Finish current file, commit output/, then run /compact."

elif [ "$CONTEXT_PCT" -le 25 ]; then
    if [ "$LAST_STATE" != "warning" ]; then
        write_state "$STATE_FILE" "warning"
        echo ""
        echo "WARNING [CIC]: Context remaining ${CONTEXT_PCT}% (${SOURCE}) — job: ${CIC_JOB_ID}"
        echo "Do not start new large tasks. Wrap up and save state."
    fi

elif [ "$CONTEXT_PCT" -le 40 ]; then
    if [ "$LAST_STATE" != "caution" ]; then
        write_state "$STATE_FILE" "caution"
        echo ""
        echo "CAUTION [CIC]: Context remaining ${CONTEXT_PCT}% (${SOURCE}) — job: ${CIC_JOB_ID}"
        echo "Be concise. Prefer targeted reads over full-file reads."
    fi
fi

exit 0
