#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
# close-job.sh <job-id> [--dry-run]
#
# The only legal awaiting_review → done transition.
#
# Until this existed, `done` was a convention: job-close.md described the
# conditions and nothing enforced them. The runner had already lost the ability
# to write `done` (it leaves awaiting_review), but any other process, or anyone
# with an editor, could still close a job with no gate run and no review.
#
# Exit 0 = closed, exit 1 = refused. A refusal names the condition that failed.
#
#   C1  jobs/<job-id>/meta.yaml exists
#   C2  its status is exactly awaiting_review
#   C3  validate-output.sh <job-id> exits GO
#   C4  jobs/<job-id>/review.md exists, is non-empty, and carries no placeholder
#   C5  if the run bypassed the spec gate, review.md acknowledges it
#
# C4 exists because validate-output.sh deliberately excludes review.md from its
# own scan (see its O1 find filter) -- so nothing checked the review artifact at
# all. An empty or TODO-riddled review.md is worth exactly as much as no review,
# which is the thing job-close.md was written to prevent.
#
# What this script does NOT do: commit and push. The commit is Vault-signed and
# is the trust artifact; job-close.md step 6 owns it, because it also knows which
# sub-job specs travel with the job. This script decides legality and performs
# the state change; publishing it stays with the orchestrator.

set -euo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"

JOB_ID=""
DRY_RUN=0
NO_COMMIT=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --no-commit) NO_COMMIT=1 ;;
        -*) echo "Unknown flag: $arg" >&2; exit 1 ;;
        *) JOB_ID="$arg" ;;
    esac
done

if [[ -z "$JOB_ID" ]]; then
    echo "Usage: $0 <job-id> [--dry-run]" >&2
    exit 1
fi

META="$WORKDIR/jobs/$JOB_ID/meta.yaml"
REVIEW="$WORKDIR/jobs/$JOB_ID/review.md"

refuse() { echo "REFUSED: $1" >&2; exit 1; }

# --- C1 ---
[[ -f "$META" ]] || refuse "C1 — nincs meta.yaml: $META"

# --- C2 ---
# Every meta read goes through meta-get.sh, which uses a real YAML parser. Two
# controls used to be bypassable with nothing but a trailing comment, because
# each reader brought its own regex and they disagreed about what the same
# document said (#29, #30).
META_GET="$WORKDIR/tools/meta-get.sh"
rc=0; STATUS=$(bash "$META_GET" "$META" status) || rc=$?
case "$rc" in
    0) ;;
    2) refuse "C2 — a meta.yaml-ben nincs status mező. Enélkül nem eldönthető, hogy a job lezárható-e." ;;
    *) refuse "C2 — a status mező nem olvasható (lásd fent). Amíg a meta nem értelmezhető, a job nem zárható." ;;
esac
if [[ "$STATUS" != "awaiting_review" ]]; then
    refuse "C2 — a job státusza '$STATUS', nem 'awaiting_review'. A done csak innen érhető el."
fi

# --- C3 ---
# `set -e` would abort here on NO-GO before the message could be written, so the
# call is guarded. The gate's own output is passed through: it names the failing
# rule, and repeating it here would be a second place to keep in sync.
if ! bash "$WORKDIR/tools/validate-output.sh" "$JOB_ID"; then
    refuse "C3 — a gépi output-kapu NO-GO-t adott (lásd fent). Javíttasd az agenttel."
fi

# --- C4 ---
[[ -f "$REVIEW" ]] || refuse "C4 — nincs review artifact: $REVIEW (sablon: /job-close 4. pont)"
[[ -s "$REVIEW" ]] || refuse "C4 — a review.md üres: $REVIEW"

# Same marker set and line-start anchoring as validate-output.sh's O3: a marker
# quoted mid-sentence is a statement about someone else's code, not an unfinished
# review.
PLACEHOLDERS=$(grep -nE '^[[:space:]]*([-*+>]|#{1,6}|[0-9]+\.)?[[:space:]]*(TODO|TBD|FIXME|XXX|kitöltendő|pótolandó)\b' \
    "$REVIEW" | head -3 || true)
if [[ -n "$PLACEHOLDERS" ]]; then
    echo "$PLACEHOLDERS" >&2
    refuse "C4 — a review.md befejezetlen (placeholder a fenti sorokban)"
fi

# --- C5 ---
# run-job.sh records spec_gate on every run. Until now nothing read it, so a job
# that never got a machine GO on its spec could walk all the way to done and the
# only evidence was a field no one opened. A trace nobody reads is not a control.
#
# An empty field means an old meta, from before run-job.sh wrote it -- refusing
# on that would make every pre-existing job uncloseable (51 of them in
# cic-factory at the time of writing), so it warns instead and says plainly that
# it cannot be verified.
# The lenient branch is for metas written before the field existed. Anything
# that merely LOOKED unreadable used to land there too and inherit that
# leniency: `spec_gate: skipped # ok` parsed as `skipped # ok`, matched no arm,
# and closed a bypassed job with nothing said (#30).
#
# Three outcomes now, not one: absent is forgiven, unreadable is refused, and an
# unknown VALUE is refused as well. That last one is the arm this control never
# had -- `*)` used to mean both "old meta" and "something I do not understand".
rc=0; SPEC_GATE=$(bash "$META_GET" "$META" spec_gate) || rc=$?
case "$rc" in
    0) ;;
    2) SPEC_GATE="__absent__" ;;
    *) refuse "C5 — a spec_gate mező nem olvasható (lásd fent). Nem igazolható, hogy a futás átment-e a spec-kapun." ;;
esac
case "$SPEC_GATE" in
    skipped)
        if ! grep -qE 'spec_gate:[[:space:]]*skipped' "$REVIEW"; then
            echo "" >&2
            echo "Ez a futás --skip-spec-gate-tel indult: a specre nem volt gépi GO." >&2
            echo "A review-nak ezt ki kell mondania. Tedd bele a review.md-be:" >&2
            echo "" >&2
            echo "    spec_gate: skipped — <mit ellenőriztél helyette, és mit nem tudsz igazolni>" >&2
            echo "" >&2
            refuse "C5 — a futás megkerülte a spec-kaput, és a review.md ezt nem ismeri el"
        fi
        echo "[!] spec_gate: skipped — a review elismerte. Ez a job gépi spec-GO nélkül futott."
        ;;
    passed)
        : ;;
    __absent__)
        echo "[WARN] a meta.yaml-ben nincs spec_gate érték — ez a job a mező bevezetése"
        echo "       előttről való. Nem igazolható, hogy a spec-kapu lefutott-e."
        ;;
    *)
        refuse "C5 — a spec_gate értéke '$SPEC_GATE', ami se passed, se skipped. Ismeretlen értéket nem lehet átmenetnek venni."
        ;;
esac

# --- C6 ---
# Mérve (#43): egy 2. attempt lezárult az 1. attempt review-jával. A close a
# fájlok MEGLÉTÉT nézte, nem azt, melyik futáshoz tartoznak — mert semmi nem
# rögzítette.
#
# A #41 óta van run_id. Ha a meta hordoz egyet, a review-nak meg kell neveznie:
# az mondja meg, hogy EZT a futást nézte valaki, nem egy korábbit. Ha a metában
# nincs run_id, a job a mező bevezetése előttről való, és ez a feltétel nem
# alkalmazható rá.
rc=0; RUN_ID=$(bash "$META_GET" "$META" run_id) || rc=$?
[[ "$rc" -eq 0 ]] || RUN_ID=""
if [[ -n "$RUN_ID" ]]; then
    if ! grep -qF "$RUN_ID" "$REVIEW"; then
        echo "" >&2
        echo "A review.md nem nevezi meg, melyik futást nézte." >&2
        echo "Ez a job jelenleg ezt futtatta:" >&2
        echo "" >&2
        echo "    run_id: $RUN_ID" >&2
        echo "" >&2
        echo "Tedd bele a review.md-be. Enélkül nem eldönthető, hogy a review" >&2
        echo "ehhez a futáshoz készült-e, vagy egy korábbihoz." >&2
        refuse "C6 — a review nincs futáshoz kötve"
    fi
else
    echo "[WARN] a meta.yaml-ben nincs run_id — ez a job a mező bevezetése"
    echo "       előttről való. Nem igazolható, melyik futást nézte a review."
fi

# --- a validált tartalom lenyomata ---
# Amit a C3 és a C4 megnézett, annak a digestje a metába kerül. Így a done
# commitból utólag eldönthető, hogy azt a tartalmat zárták-e le, amit a kapu
# látott.
RESULT_DIGEST=$(
    { find "$WORKDIR/jobs/$JOB_ID/output" -type f -print0 2>/dev/null | sort -z | xargs -0r cat
      cat "$REVIEW"
    } | sha256sum | cut -d' ' -f1
)

if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: mind a négy feltétel teljesül, a job lezárható."
    exit 0
fi

# --- transition ---
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# A `^\s+completed:` minta MINDEN behúzott completed: sort átírta, nem csak a
# timestamps alattit -- ugyanaz az osztály, amit a #40 a run-job.sh-ban lezárt.
# Ez a fájl kimaradt a söprésből.
#
# A result_digest azt rögzíti, MIT látott a kapu. A close és a commit között
# eddig kicserélhető volt az output, és a done commit olyan tartalmat vitt,
# amit a kapu soha nem látott (#43).
bash "$WORKDIR/tools/meta-set.sh" "$META" \
    'status=done' \
    "timestamps.completed=$NOW" \
    "result_digest=$RESULT_DIGEST" \
    "reviewed_run_id=$RUN_ID"

bash "$WORKDIR/tools/update-index.sh"

echo "[✓] $JOB_ID — done ($NOW)"

# Mérve (#43): a close eddig nem commitolt, csak kiírta a parancsokat. A
# validáció és a kézi commit között az output kicserélhető volt, és a done
# commit olyan tartalmat vitt, amit a kapu soha nem látott. Ehhez nem kellett
# se két attempt, se két folyamat.
#
# Ezért a close commitolja azt, amit validált. A commit továbbra is
# Vault-aláírt: a commit-msg hook ugyanúgy lefut.
if [[ "$NO_COMMIT" -eq 1 ]]; then
    echo ""
    echo "[!] --no-commit: a lezárás megtörtént, de a commit a tiéd."
    echo "    A validáció és a commit között a tartalom megváltozhat — a"
    echo "    meta result_digest mezője rögzíti, mit látott a kapu:"
    echo "      $RESULT_DIGEST"
    echo "  git add jobs/$JOB_ID/ jobs/index.yaml"
    echo "  git commit -m \"job: $JOB_ID — done + output + review\""
    echo "  git push"
else
    # A `set -e` miatt guard: egy nem-git munkafában a lezárás ugyanúgy
    # megtörtént, csak nincs mit commitolni.
    if ! git -C "$WORKDIR" rev-parse --git-dir >/dev/null 2>&1; then
        echo "[!] $WORKDIR nem git munkafa — a lezárás megtörtént, commit nincs." >&2
        exit 0
    fi
    git -C "$WORKDIR" add "jobs/$JOB_ID/meta.yaml" "jobs/$JOB_ID/review.md" \
        "jobs/$JOB_ID/output" jobs/index.yaml || true
    if git -C "$WORKDIR" commit -q -m "job: $JOB_ID — done + output + review" \
           -- "jobs/$JOB_ID/meta.yaml" "jobs/$JOB_ID/review.md" \
              "jobs/$JOB_ID/output" jobs/index.yaml; then
        echo "[*] Commitolva — pontosan az a tartalom, amit a kapu látott."
        if git -C "$WORKDIR" push -q 2>/dev/null; then
            echo "[*] Kipusholva."
        else
            echo "[!] A push nem sikerült; a commit helyben megvan." >&2
            echo "    git -C $WORKDIR push" >&2
        fi
    else
        echo "[!] A commit nem sikerült. A meta done, de a bizonyíték nincs kint." >&2
    fi
fi
