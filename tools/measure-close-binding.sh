#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# measure-close-binding.sh — a #43 (FC-06) állításainak mérése.
#
# NEM teszt-suite, és nem fut a kapuban: a célja, hogy a tervezés MÉRT alapon
# álljon. Ugyanaz a minta, ami a #41-nél kiderítette, hogy az audit hat
# állításából kettő hamis volt.
#
# A #43 azt állítja, hogy a close a fájlok MEGLÉTÉT nézi, nem azt, melyik
# futáshoz tartoznak — tehát egy új attempt lezárható a korábbi review-jával.
#
# Futtatás:  bash tools/measure-close-binding.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SRC/.." && pwd)"

say()     { printf '\n\033[1m%s\033[0m\n' "$1"; }
verdict() { printf '  → %s\n' "$1"; }

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
    cat > "$r/repo/jobs/t/input.md" <<'EOF'
# Teszt job
## Output
`output/report.md`
EOF
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
run_job()  { local r="$1"; shift
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo \
        bash tools/run-job.sh t agent-01 --skip-spec-gate "$@" </dev/null ) >"$r/run.log" 2>&1; echo $?; }
close_job() { local r="$1"; shift
    ( cd "$r/repo" && bash tools/close-job.sh t "$@" </dev/null ) >"$r/close.log" 2>&1; echo $?; }
field()    { bash "$SRC/meta-get.sh" "$1/repo/jobs/t/meta.yaml" "$2" 2>/dev/null; }

# Egy elfogadható output és review, hogy a C3/C4 ne emiatt bukjon.
write_output() {   # <root> <megjelölés>
    cat > "$1/repo/jobs/t/output/report.md" <<EOF
# Riport — $2
| Állítás | Státusz | Bizonyíték | Verifikációs módszer | Kockázat |
|---|---|---|---|---|
| A dolog működik | igazolt | a mérés kimenete | újrafuttatható | alacsony |
EOF
}
# A review-nak el kell ismernie a spec_gate: skipped-et, különben a C5 áll meg
# ELŐBB, és a mérés nem a kötést mérné, hanem a saját fixture-hibáját. (Az első
# változat pontosan ebbe futott bele: mindkét eset C5-tel bukott.)
write_review() {
    printf '# Review — %s\n\nspec_gate: skipped — kézzel néztem át a specet\n\n## Amit ellenőriztem\n- a kapu zöld\n' \
        "$2" > "$1/repo/jobs/t/review.md"
}
# Csak a job path-jait commitoljuk: a workspace beágyazott git repo, és a
# `git add -A` figyelmeztetést dob rá.
commit_done() { git -C "$1/repo" add jobs/t/meta.yaml jobs/t/review.md jobs/t/output jobs/index.yaml >/dev/null 2>&1
                git -C "$1/repo" commit -qm "job: t — done + output + review" >/dev/null 2>&1; }

# ── 1. Lezárható-e egy ÚJ attempt a KORÁBBI attempt review-jával? ───────────
say "1. Cross-attempt close: régi review, új attempt (#43)"
R=$(mkfactory)
run_job "$R" >/dev/null
A1_RUN=$(field "$R" run_id); A1_ATT=$(field "$R" attempt)
write_output "$R" "első attempt"
write_review "$R" "első attempt"
echo "  1. attempt: run_id=$A1_RUN attempt=$A1_ATT, review+output megírva"

run_job "$R" --force >/dev/null
A2_RUN=$(field "$R" run_id); A2_ATT=$(field "$R" attempt)
echo "  2. attempt: run_id=$A2_RUN attempt=$A2_ATT"
echo "  a review.md és az output/ VÁLTOZATLAN — az elsőé"

rc=$(close_job "$R")
echo "  close exit=$rc, státusz=$(field "$R" status)"
if [[ "$rc" -eq 0 && "$(field "$R" status)" == "done" ]]; then
    verdict "REPRODUKÁLT — a 2. attempt lezárult az 1. attempt review-jával"
else
    verdict "nem zárult le (exit $rc) — nézd meg, mi állította meg"
    grep -m2 'REFUSED' "$R/close.log" | sed 's/^/     /'
fi
rm -rf "$R"

# ── 2. Változhat-e az output a validáció UTÁN, észrevétlenül? ───────────────
say "2. TOCTOU: a validált output a close után változik"
R=$(mkfactory)
run_job "$R" >/dev/null
write_output "$R" "eredeti"
write_review "$R" "eredeti"
rc=$(close_job "$R")
echo "  close exit=$rc, státusz=$(field "$R" status)"
# a close NEM commitol -- az ember teszi, később
printf '# Riport — KICSERÉLVE\nse tábla, se bizonyíték\n' > "$R/repo/jobs/t/output/report.md"
echo "  az output a close UTÁN kicserélve, kapun át nem ment"
commit_done "$R"
COMMITTED=$(git -C "$R/repo" show HEAD:jobs/t/output/report.md | head -1)
echo "  a done commitban ez van: $COMMITTED"
if [[ "$COMMITTED" == *KICSERÉLVE* ]]; then
    verdict "REPRODUKÁLT — a done commit olyan outputot hordoz, amit a kapu nem látott"
else
    verdict "nem reprodukálódott"
fi
rm -rf "$R"

# ── 3. Visszafejthető-e a done commitból, MELYIK futás eredménye? ───────────
say "3. A done commitból visszafejthető-e a kötés?"
R=$(mkfactory)
run_job "$R" >/dev/null
write_output "$R" "x"; write_review "$R" "x"
close_job "$R" >/dev/null
commit_done "$R"
echo "  a done meta run_id-je:  $(field "$R" run_id)"
echo "  attempt:                $(field "$R" attempt)"
echo "  a review.md-ben van-e hivatkozás a futásra? $(grep -c 'run_id\|attempt' "$R/repo/jobs/t/review.md")"
echo "  az outputban?                                $(grep -c 'run_id\|attempt' "$R/repo/jobs/t/output/report.md")"
verdict "a run_id a metában megvan (#41 óta); a review és az output semmihez nincs kötve"
rm -rf "$R"
