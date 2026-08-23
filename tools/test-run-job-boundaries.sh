#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# Két határ a run-job.sh-ban, mindkettő a valódi belépési ponton mérve.
#
#   A prompt határa (#31)
#     Az input.md-t csupasz `envsubst` futtatta: a wrapper TELJES környezetét
#     behelyettesítette. Ez egyszerre szivárgás és rongálás -- ami exportálva
#     van, bekerül a promptba; ami nincs, azt üresre cseréli. A cic-factory
#     specjeiben mindkettőre van élő példa: $VAULT_TOKEN az egyikben,
#     `{"$ref": ...}` és `$schema` a másikban.
#
#   A path határa (#32)
#     A job-id-ből path épül, aminek a végén `rm -rf` van, és az alakját semmi
#     nem nézte meg.
#
# Az echo runner alapból a kapott promptot adja vissza eredményként, tehát a
# prompt az agent-output fájlban mérhető -- production-részlet másolása nélkül.

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
def quote(o):
    if isinstance(o, dict):  return {k: quote(v) for k, v in o.items()}
    if isinstance(o, list):  return [quote(v) for v in o]
    if isinstance(o, str):   return Q(o)
    return o
yaml.dump(quote(d), open(f"{root}/repo/jobs/t/meta.yaml", "w", encoding="utf-8"),
          sort_keys=False, allow_unicode=True)
PY
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
commit_spec() { git -C "$1/repo" add -A >/dev/null 2>&1; git -C "$1/repo" commit -qm spec --no-verify >/dev/null 2>&1; }
# `env` és nem csupasz értékadás: a "$@"-ből kibontott NAME=VALUE a bash
# számára parancsnév, nem értékadás -- az első változatban a futás el sem
# indult, és a "nincs benne a titok" assertionök egy üres fájlon mentek át.
run_job() {
    local r="$1"; shift
    ( cd "$r/repo" && env HOME="$r/home" CIC_AGENT_RUNNER=echo "$@" \
        bash tools/run-job.sh t agent-01 --skip-spec-gate ) >"$r/run.log" 2>&1
    echo $?
}
# Az agent-output a workspace-klónban keletkezik, nem a live fában.
prompt_of() { cat "$(find "$1" -name 'agent-output*.md' 2>/dev/null | head -1)" 2>/dev/null; }
# Ami nincs, abban semmi nincs benne. Minden szivárgás-mérés előtt le kell
# mérni, hogy a prompt egyáltalán megszületett.
prompt_len() { prompt_of "$1" | wc -c; }

echo "A prompt határa (#31)"
R=$(mkfactory)
cat > "$R/repo/jobs/t/input.md" <<'EOF'
# Teszt job
Titok a környezetből: [$VAULT_TOKEN] [$MY_CANARY]
Séma-hivatkozás: {"$ref": "#/defs/X"} és $schema és ${encoded}
Runner adja: $JOB_ID a $FACTORY_CLONE alatt, branch $FEATURE_BRANCH
Telepítés adja: $CIC_RELAY_PATH
## Output
`output/report.md`
EOF
commit_spec "$R"
run_job "$R" VAULT_TOKEN=hvs.LEAKED-SECRET MY_CANARY=CANARY-VALUE \
             CIC_RELAY_PATH=/opt/relay FACTORY_PROMPT_VARS="CIC_RELAY_PATH" >/dev/null
P=$(prompt_of "$R")
check "a prompt egyáltalán megszületett" "1" "$([ "$(prompt_len "$R")" -gt 100 ] && echo 1 || echo 0)"
check "  a Vault token NINCS a promptban"  "0" "$(printf '%s' "$P" | grep -c 'hvs.LEAKED-SECRET')"
check "  a canary sincs"                 "0" "$(printf '%s' "$P" | grep -c 'CANARY-VALUE')"
check "  a \$VAULT_TOKEN szó szerint marad" "1" "$(printf '%s' "$P" | grep -c '\[\$VAULT_TOKEN\]')"
check "  a {\"\$ref\"} nem üresedett ki"  "1" "$(printf '%s' "$P" | grep -c '"\$ref"')"
check "  a \$schema megmaradt"           "1" "$(printf '%s' "$P" | grep -c '\$schema')"
check "  a \${encoded} megmaradt"        "1" "$(printf '%s' "$P" | grep -c '\${encoded}')"
check "  a \$JOB_ID behelyettesült"      "1" "$(printf '%s' "$P" | grep -c 'Runner adja: t a ')"
check "  a \$FEATURE_BRANCH behelyettesült" "1" "$(printf '%s' "$P" | grep -c 'branch feature/t')"
check "  a telepítés változója behelyettesült" "1" "$(printf '%s' "$P" | grep -c '/opt/relay')"
rm -rf "$R"

echo
echo "  Az allowlistán kívüli név akkor sem jön be, ha be van állítva"
R=$(mkfactory)
printf '# T\nÉrték: [$OTHER_VAR]\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
run_job "$R" OTHER_VAR=SHOULD-NOT-APPEAR >/dev/null
check "nem helyettesült be" "0" "$(prompt_of "$R" | grep -c 'SHOULD-NOT-APPEAR')"
rm -rf "$R"

echo
echo "  A beállított, de nem engedélyezett változóra figyelmeztet"
# Ez a néma degradáció ellen van: a `${CIC_RELAY_PATH}` szó szerint maradna az
# agent promptjában, és semmi nem szólna róla.
R=$(mkfactory)
printf '# T\nÚt: $MY_DEPLOY_PATH és séma: {"$ref": "x"}\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
run_job "$R" MY_DEPLOY_PATH=/opt/valami >/dev/null
# MAGÁRA A FIGYELMEZTETŐ SORRA mérünk, nem az egész naplóra: az tartalmazza a
# git push kimenetét is, benne a `refs/heads/...`-szal. Az első változat a
# csupasz `ref` részstringre grepelt az egész logban, lokálisan átment, CI-ban
# elbukott -- a napló ott bővebb.
WARNLINE=$(grep 'szó szerint maradnak' "$R/run.log" || true)
check "figyelmeztet"                   "1" "$(printf '%s' "$WARNLINE" | grep -c 'MY_DEPLOY_PATH')"
check "  megmondja hova kell felvenni" "1" "$(grep -c 'FACTORY_PROMPT_VARS' "$R/run.log")"
# A $ref nincs beállítva a környezetben, tehát nem szól rá -- különben minden
# kódrészletet tartalmazó spec zajt termelne.
check "  a \$ref-et NEM sorolja fel"  "0" "$(printf '%s' "$WARNLINE" | grep -cw 'ref')"
rm -rf "$R"

echo
echo "  Az engedélyezett változóra nem figyelmeztet"
R=$(mkfactory)
printf '# T\nÚt: $MY_DEPLOY_PATH\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
run_job "$R" MY_DEPLOY_PATH=/opt/valami FACTORY_PROMPT_VARS="MY_DEPLOY_PATH" >/dev/null
check "nincs figyelmeztetés" "0" "$(grep -c 'szó szerint maradnak' "$R/run.log")"
check "  és be is helyettesült" "1" "$(prompt_of "$R" | grep -c '/opt/valami')"
rm -rf "$R"

echo
echo "  Hibás vagy titoknak látszó név a listában"
R=$(mkfactory)
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
run_job "$R" FACTORY_PROMPT_VARS="9BAD NAME-WITH-DASH MY_TOKEN" MY_TOKEN=x >/dev/null
check "az érvénytelen nevet jelzi"  "2" "$(grep -c 'nem érvényes változónév' "$R/run.log")"
check "  a titoknak látszót is jelzi" "1" "$(grep -c 'titoknak látszik' "$R/run.log")"
rm -rf "$R"

echo
echo "kb_focus és max_turns — a régi regex melyiken bukott (#40)"
# A minta csak a dupla idézőjeles inline listát ismerte, a blokk-lista elemeibe
# pedig a sorvégi komment is beleragadt. A max_turns nem volt szekcióhoz kötve.
R=$(mkfactory)
printf '# T\nA fókusz szerepeljen a promptban.\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
# A sablonban MÁR van usage: szekció; egy másodikat hozzáfűzve duplikált
# kulcs keletkezne, és a fail-closed olvasó megállítaná a futást. (Az első
# változat pontosan ezt csinálta -- a saját őr fogta meg.)
python3 - "$R/repo/jobs/t/meta.yaml" <<'PYX2'
import sys
p = sys.argv[1]
c = open(p, encoding="utf-8").read()
c = c.replace('kb_focus: []', "kb_focus: [c781, 'n9']")
open(p, "w", encoding="utf-8").write(c)
PYX2
bash "$SRC/meta-set.sh" "$R/repo/jobs/t/meta.yaml" 'usage.max_turns=999' 
commit_spec "$R"
run_job "$R" >/dev/null
P=$(prompt_of "$R")
check "az idézőjel nélküli ID bekerült"  "1" "$(printf '%s' "$P" | grep -c 'c781')"
check "  az aposztrófos is"              "1" "$(printf '%s' "$P" | grep -c 'n9')"
check "  a usage.max_turns NEM lett a limit" "0" "$(grep -c 'max-turns 999' "$R/run.log")"
rm -rf "$R"

echo
echo "Az agent-konfiguráció helyét a job mondja meg (#42)"
# Az agent.config_dir mező a sémában régóta benne volt, minden meta kitöltötte,
# és a run-job.sh SEHOL nem olvasta — beégetett ~/.claude-personal utat
# származtatott helyette. Egy dokumentált mező, amit senki nem olvas, hamis
# konfigurációs felület.
R=$(mkfactory)
NONCLAUDE="$R/home/sajat-agent-config"
mkdir -p "$NONCLAUDE"
bash "$SRC/meta-set.sh" "$R/repo/jobs/t/meta.yaml" "agent.config_dir=$NONCLAUDE"
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
check "lefut Claude-alakú könyvtár nélkül" "0" "$(run_job "$R")"
rm -rf "$R"

echo
echo "  a nem létező könyvtárnál megnevezi a forrást"
R=$(mkfactory)
bash "$SRC/meta-set.sh" "$R/repo/jobs/t/meta.yaml" "agent.config_dir=$R/home/nincs-ilyen"
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
check "elutasít" "1" "$(run_job "$R")"
check_run() { grep -c "$1" "$R/run.log"; }
check "  megnevezi a könyvtárat" "1" "$(grep -c 'nincs-ilyen' "$R/run.log")"
check "  és hogy honnan jött" "1" "$(grep -c 'meta.yaml agent.config_dir' "$R/run.log")"
rm -rf "$R"

echo
echo "  üres mező → az alapértelmezés, és ezt is kimondja"
R=$(mkfactory)
bash "$SRC/meta-set.sh" "$R/repo/jobs/t/meta.yaml" 'agent.config_dir='
rm -rf "$R/home/.claude-personal"
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
check "elutasít" "1" "$(run_job "$R")"
check "  az alapértelmezést nevezi meg forrásként" "1" \
    "$(grep -c 'alapértelmezés' "$R/run.log")"
rm -rf "$R"

echo "A path határa (#32)"
# Az exit code itt NEM mér semmit: ellenőrzés nélkül is 1-gyel áll le, csak
# később és más okból ("Nem létezik: .../jobs/../../X/meta.yaml"). Az első
# változatom pontosan ezt a hibát követte el -- a mutáció zölden hagyta a
# suite-ot. Az assertion ezért az OKRA megy, és arra, hogy az elutasítás a
# meta-keresés ELŐTT történik.
R=$(mkfactory)
echo "ne törölj ki" > "$R/CANARY.txt"
bad_id() {
    ( cd "$R/repo" && HOME="$R/home" CIC_AGENT_RUNNER=echo \
      bash tools/run-job.sh "$1" "${2:-agent-01}" --skip-spec-gate ) >"$R/bad.log" 2>&1
    echo $?
}
for bad in '../../CANARY' '/etc/passwd' 'a b' 'a;rm -rf /' 'ékezet'; do
    check "elutasít: '$bad'" "1" "$(bad_id "$bad")"
    # Bármelyik azonosító-szabály tüzelhet -- a '../../X' például ponttal
    # kezdődik, tehát azon bukik el, nem a karakterkészleten. A lényeg, hogy
    # AZONOSÍTÓ-szabályra hivatkozzon, ne valami későbbi hiányra.
    if grep -qE 'A job-id (nem kezdődhet|csak )' "$R/bad.log"; then
        echo "  PASS    azonosító-szabályt nevez meg"; ((pass++))
    else
        echo "  FAIL    nem azonosító-szabályra hivatkozik: $(head -1 "$R/bad.log")"; ((fail++))
    fi
    check "  nem jutott el a meta-keresésig" "0" "$(grep -c 'Nem létezik' "$R/bad.log")"
done
check "elutasít: '-flag'" "1" "$(bad_id '-flag')"
check "  a kötőjeles kezdést nevezi meg" "1" "$(grep -c 'nem kezdődhet kötőjellel' "$R/bad.log")"
check "elutasít: '.hidden'" "1" "$(bad_id '.hidden')"
check "  a pontos kezdést nevezi meg" "1" "$(grep -c 'nem kezdődhet ponttal' "$R/bad.log")"
check "  a repón kívüli canary megvan" "1" "$([ -f "$R/CANARY.txt" ] && echo 1 || echo 0)"

echo
echo "  Az agent-id is ellenőrzött"
check "elutasít" "1" "$(bad_id t '../../evil')"
check "  az agent-id-t nevezi meg" "1" "$(grep -c 'A agent-id' "$R/bad.log")"
rm -rf "$R"

echo
# A containment-ellenőrzésnek (a feloldott workspace a jobs/ alatt van-e)
# NINCS megkülönböztető tesztje, és ezt jobb kimondani, mint látszatot kelteni:
# valid_id mellett nem tudok olyan bemenetet előállítani, ami a törlésig eljut
# ÉS kivezet a fából. Backstop marad arra az esetre, ha valid_id valaha
# meggyengül. A mellette álló symlink-ellenőrzést az alábbi eset méri.

echo "  Az érvényes azonosító átmegy (különben a fentiek semmit nem mondanak)"
R=$(mkfactory)
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
check "lefut" "0" "$(run_job "$R")"
rm -rf "$R"

echo
echo "  A workspace nem törölhető symlinken keresztül"
R=$(mkfactory)
printf '# T\n## Output\n`output/report.md`\n' > "$R/repo/jobs/t/input.md"
commit_spec "$R"
echo "kívülálló" > "$R/outside.txt"
mkdir -p "$R/elsewhere"
ln -s "$R/elsewhere" "$R/repo/jobs/t/workspace"
check "elutasít" "1" "$(run_job "$R")"
check "  a symlink célja megvan" "1" "$([ -d "$R/elsewhere" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
