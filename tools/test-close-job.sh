#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Every refusal in close-job.sh, measured against a fixture that actually
# violates it. A gate is only worth having if it can go red, and the way to know
# is to make it go red on purpose.
#
# Each case builds a throwaway workdir -- tools/ plus one job -- so nothing here
# touches the real jobs/.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}

# The refusal messages carry a path, so the assertion is on the reason, not on
# the whole line.
check_log() {
    local desc="$1" want="$2" log="$3"
    if grep -qF -- "$want" "$log"; then echo "  PASS  $desc"; ((pass++))
    else echo "  FAIL  $desc — nem található: '$want'"; ((fail++)); fi
}

check_reason() {
    local desc="$1" want="$2" log="$3"
    if grep -qF "$want" "$log"; then echo "  PASS  $desc"; ((pass++))
    else echo "  FAIL  $desc — nem található: '$want'"; ((fail++)); fi
}

# A job that passes validate-output: a declared output that exists, carries a
# claim-evidence table and no placeholder, and a spec that does not ask for a
# status determination (or O4 would demand a reachability artifact too).
mkjob() {
    local root="$1" status="$2" spec_gate="${3-}"
    mkdir -p "$root/tools" "$root/jobs/t/output"
    cp "$SRC/close-job.sh" "$SRC/validate-output.sh" "$SRC/update-index.sh" \
       "$SRC/meta-get.sh" "$SRC/meta-set.sh" "$root/tools/"
    cat > "$root/jobs/t/input.md" <<'EOF'
# Teszt job
## Output
- `report.md`
EOF
    cat > "$root/jobs/t/output/report.md" <<'EOF'
# Riport
| Állítás | Státusz | Bizonyíték | Verifikációs módszer | Kockázat |
|---|---|---|---|---|
| A dolog működik | igazolt | a mérés kimenete | újrafuttatható | alacsony |
EOF
    cat > "$root/jobs/t/meta.yaml" <<EOF
schema_version: "1.0"
job_id: "t"
status: "$status"
${spec_gate:+spec_gate: \"$spec_gate\"}
timestamps:
  created: "2026-01-01T00:00:00Z"
  started: "2026-01-01T00:00:00Z"
  completed: ""
EOF
}

run_close() {
    local root="$1"; shift
    bash "$root/tools/close-job.sh" t "$@" >"$root/out.log" 2>&1
    echo $?
}

status_of() { grep '^status:' "$1/jobs/t/meta.yaml" | head -1 | awk -F'"' '{print $2}'; }

echo "C1 — nincs meta.yaml"
T=$(mktemp -d); mkjob "$T" awaiting_review; rm "$T/jobs/t/meta.yaml"
check "elutasít" "1" "$(run_close "$T")"
grep -q 'C1' "$T/out.log" && { echo "  PASS  a C1-et nevezi meg"; ((pass++)); } || { echo "  FAIL  nem a C1-et nevezi"; ((fail++)); }
rm -rf "$T"

echo
echo "C2 — a done csak awaiting_review-ból érhető el"
for st in pending running done error; do
    T=$(mktemp -d); mkjob "$T" "$st"
    check "elutasít '$st' állapotot" "1" "$(run_close "$T")"
    check "  a státusz érintetlen" "$st" "$(status_of "$T")"
    rm -rf "$T"
done

echo
echo "C3 — a gépi output-kapu NO-GO-ja megállítja"
T=$(mktemp -d); mkjob "$T" awaiting_review
# claim-evidence tábla eltávolítva → O2 bukik
printf '# Riport\nsemmi tábla\n' > "$T/jobs/t/output/report.md"
echo "review" > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check "  a státusz érintetlen" "awaiting_review" "$(status_of "$T")"
grep -q 'C3' "$T/out.log" && { echo "  PASS  a C3-at nevezi meg"; ((pass++)); } || { echo "  FAIL  nem a C3-at nevezi"; ((fail++)); }
rm -rf "$T"

echo
echo "C4 — review artifact nélkül nincs lezárás"
# Az exit kód önmagában kevés: a hiányzó és az üres eset ugyanúgy 1-gyel tér
# vissza, mert `[[ -s ]]` nemlétező fájlra is hamis. Emiatt a `-f` ellenőrzés
# kivétele észrevétlen maradt, amíg a teszt csak a kódot nézte. Az indokot is
# meg kell nézni, különben egymást takaró ellenőrzéseket nem lehet mérni.
T=$(mktemp -d); mkjob "$T" awaiting_review
check "hiányzó review.md → elutasít" "1" "$(run_close "$T")"
check_reason "  és a hiányra hivatkozik" "C4 — nincs review artifact" "$T/out.log"

: > "$T/jobs/t/review.md"
check "üres review.md → elutasít" "1" "$(run_close "$T")"
check_reason "  és az ürességre hivatkozik" "C4 — a review.md üres" "$T/out.log"

printf '# Review\n- TODO: majd kitöltöm\n' > "$T/jobs/t/review.md"
check "placeholderes review.md → elutasít" "1" "$(run_close "$T")"
check_reason "  és a befejezetlenségre hivatkozik" "C4 — a review.md befejezetlen" "$T/out.log"

check "  a státusz mindvégig érintetlen" "awaiting_review" "$(status_of "$T")"
rm -rf "$T"

echo
echo "C5 — a megkerült spec-kaput a review-nak el kell ismernie"
T=$(mktemp -d); mkjob "$T" awaiting_review skipped
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "elismerés nélkül elutasít" "1" "$(run_close "$T")"
check_reason "  a C5-öt nevezi meg" "C5 — a futás megkerülte a spec-kaput" "$T/out.log"
check_log "  megmondja mit kell beírni" "spec_gate: skipped —" "$T/out.log"
check "  a státusz érintetlen" "awaiting_review" "$(status_of "$T")"

printf '# Review\n\nspec_gate: skipped — kézzel néztem át a specet, a K9 nem igazolható.\n' \
    > "$T/jobs/t/review.md"
check "elismeréssel lezárható" "0" "$(run_close "$T")"
check "  a státusz done" "done" "$(status_of "$T")"
rm -rf "$T"

# Az idézőjel nélküli alak: korábban üresnek olvasódott, és a kikényszerítés
# némán kimaradt. Két karakter eltávolítása nem kapcsolhatja ki a C5-öt.
T=$(mktemp -d); mkjob "$T" awaiting_review skipped
sed -i 's/^spec_gate: .*/spec_gate: skipped/' "$T/jobs/t/meta.yaml"
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "idézőjel nélküli 'skipped' is elutasít" "1" "$(run_close "$T")"
check_reason "  a C5-öt nevezi meg" "C5 — a futás megkerülte a spec-kaput" "$T/out.log"
rm -rf "$T"

T=$(mktemp -d); mkjob "$T" awaiting_review passed
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "spec_gate: passed → nem kér elismerést" "0" "$(run_close "$T")"
rm -rf "$T"

# Régi meta: a mező hiányzik. Elutasítani annyi lenne, mint a mező bevezetése
# előtti összes jobot lezárhatatlanná tenni (51 db a cic-factory-ban), ezért
# figyelmeztet — de kimondja, hogy nem igazolható.
T=$(mktemp -d); mkjob "$T" awaiting_review
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "hiányzó spec_gate → lezárható" "0" "$(run_close "$T")"
check_log "  de figyelmeztet, hogy nem igazolható" "nincs spec_gate érték" "$T/out.log"
rm -rf "$T"

echo
echo "C5 — sorvégi komment nem kerülheti meg a spec-kaput (#30)"
# A régi olvasó ezt `skipped # a review majd`-nak látta, egyik case-ágra sem
# illett, és a megengedő "régi meta" ágon a job lezárult. YAML szerint az érték
# `skipped`, tehát a review-elismerés kötelező.
T=$(mktemp -d); mkjob "$T" awaiting_review
sed -i 's/^status: "awaiting_review"$/status: "awaiting_review"\nspec_gate: skipped # a review majd/' "$T/jobs/t/meta.yaml"
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check_reason "  a C5-öt nevezi meg" "C5" "$T/out.log"
check "  a státusz érintetlen" "awaiting_review" "$(status_of "$T")"
rm -rf "$T"

echo
echo "C5 — a review elismerése mellett ugyanez átmegy"
T=$(mktemp -d); mkjob "$T" awaiting_review
sed -i 's/^status: "awaiting_review"$/status: "awaiting_review"\nspec_gate: skipped # a review majd/' "$T/jobs/t/meta.yaml"
printf '# Review\nspec_gate: skipped — kézzel néztem át a specet\n' > "$T/jobs/t/review.md"
check "átmegy" "0" "$(run_close "$T")"
check "  a státusz done" "done" "$(status_of "$T")"
rm -rf "$T"

echo
echo "C5 — ismeretlen érték nem átmenet"
# Ez az ág korábban nem létezett: a `*)` egyszerre jelentette azt, hogy "régi
# meta" és azt, hogy "ezt nem értem", és mindkettőt átengedte.
T=$(mktemp -d); mkjob "$T" awaiting_review banana
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check_reason "  megnevezi az értéket" "banana" "$T/out.log"
rm -rf "$T"

echo
echo "C2 — nem értelmezhető meta nem zárható (fail closed)"
T=$(mktemp -d); mkjob "$T" awaiting_review
printf 'status: "awaiting_review\nagent:\n  model: "opus\n' > "$T/jobs/t/meta.yaml"
printf '# Review\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check_reason "  a C2-t nevezi meg" "C2" "$T/out.log"
rm -rf "$T"

echo
echo "C2 — duplikált status kulcs nem zárható"
# Regexes olvasó az elsőt látja, YAML-parser az utolsót. Egy dokumentum, ami
# attól függ, ki nézi, nem alap egy lifecycle-átmenethez.
T=$(mktemp -d); mkjob "$T" awaiting_review
printf 'status: "awaiting_review"\nstatus: "done"\n' > "$T/jobs/t/meta.yaml"
printf '# Review\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check_reason "  a C2-t nevezi meg" "C2" "$T/out.log"
rm -rf "$T"

echo
echo "Happy path — mind a négy feltétel teljesül"
T=$(mktemp -d); mkjob "$T" awaiting_review
printf '# Review\n## Amit ellenőriztem\n- a kapu zöld\n' > "$T/jobs/t/review.md"
check "--dry-run átmegy" "0" "$(run_close "$T" --dry-run)"
check "  de NEM zár le" "awaiting_review" "$(status_of "$T")"
check "éles futás átmegy" "0" "$(run_close "$T")"
check "  a státusz done" "done" "$(status_of "$T")"
grep -qE '^\s+completed: "20' "$T/jobs/t/meta.yaml" && { echo "  PASS  completed timestamp kitöltve"; ((pass++)); } \
    || { echo "  FAIL  completed üres"; ((fail++)); }
check "másodszor már elutasít (a done nem awaiting_review)" "1" "$(run_close "$T")"
rm -rf "$T"

echo
echo "C6 — a review nevezze meg, melyik futást nézte (#43)"
# Mérve: egy 2. attempt lezárult az 1. attempt review-jával. A close a fájlok
# meglétét nézte, nem azt, melyik futáshoz tartoznak.
T=$(mktemp -d); mkjob "$T" awaiting_review
bash "$SRC/meta-set.sh" "$T/jobs/t/meta.yaml" 'run_id=RUN-AAA' 'attempt=1'
printf '# Review\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "run_id nélküli review → elutasít" "1" "$(run_close "$T")"
check_reason "  a C6-ot nevezi meg" "C6" "$T/out.log"
check_reason "  kiírja a futás azonosítóját" "RUN-AAA" "$T/out.log"
check "  a státusz érintetlen" "awaiting_review" "$(status_of "$T")"
rm -rf "$T"

echo
echo "  a MÁSIK attempt review-ja sem elég"
T=$(mktemp -d); mkjob "$T" awaiting_review
bash "$SRC/meta-set.sh" "$T/jobs/t/meta.yaml" 'run_id=RUN-BBB' 'attempt=2'
printf '# Review\nrun_id: RUN-AAA\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "elutasít" "1" "$(run_close "$T")"
check_reason "  a C6-ot nevezi meg" "C6" "$T/out.log"
rm -rf "$T"

echo
echo "  a SAJÁT futás review-ja átmegy, és rögzül a kötés"
T=$(mktemp -d); mkjob "$T" awaiting_review
bash "$SRC/meta-set.sh" "$T/jobs/t/meta.yaml" 'run_id=RUN-BBB' 'attempt=2'
printf '# Review\nrun_id: RUN-BBB\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "átmegy" "0" "$(run_close "$T")"
check "  a státusz done" "done" "$(status_of "$T")"
check "  reviewed_run_id rögzítve" "RUN-BBB" "$(bash "$SRC/meta-get.sh" "$T/jobs/t/meta.yaml" reviewed_run_id)"
check "  result_digest rögzítve (sha256)" "1" \
    "$(bash "$SRC/meta-get.sh" "$T/jobs/t/meta.yaml" result_digest | grep -cE '^[0-9a-f]{64}$')"
rm -rf "$T"

echo
echo "  run_id nélküli meta (a mező bevezetése előtti job) → figyelmeztet, átenged"
T=$(mktemp -d); mkjob "$T" awaiting_review
printf '# Review\n## Amit ellenőriztem\n- ok\n' > "$T/jobs/t/review.md"
check "átmegy" "0" "$(run_close "$T")"
check_reason "  de kimondja, hogy nem igazolható" "nincs run_id" "$T/out.log"
rm -rf "$T"

echo
echo "==== $pass PASS / $fail FAIL ===="
[[ "$fail" -eq 0 ]]
