#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# A hook-provenance checker tud-e pirosat adni (#82)?
#
# A mért hiba: a `core.hooksPath` egy repón kívüli megosztott könyvtárra
# mutatott, benne a signer elavult MÁSOLATÁVAL — a #38 és a #28 javítása két
# kiadás óta nem volt a lokális trust path-ban, és semmi nem szólt.
#
# Minden eset a VALÓDI checkert futtatja egy külön fixture-repón. Ami itt
# számít: a checker megkülönbözteti-e a legitim wrappert az elavult másolattól,
# és fail closed-e, amikor nem tudja eldönteni.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}
check_log() {
    if grep -qF -- "$2" "$3"; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — nem található: '$2'"; ((fail++)); fi
}

ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# Fixture-repó a kiadott signerrel és a checkerrel a helyén.
mkfix() {   # <név>
    local r="$ROOT/$1"
    mkdir -p "$r/tools" "$r/shared"
    cp "$SRC/git_hook_commit-msg.sh" "$SRC/check-hook-provenance.sh" \
       "$SRC/init-hooks.sh" "$r/tools/"
    git -C "$r" init -q
    git -C "$r" config user.email t@t
    git -C "$r" config user.name t
    echo "$r"
}
run() { bash "$1/tools/check-hook-provenance.sh" >"$1/out.log" 2>&1; echo $?; }

echo "1. Symlink a kiadott signerre → GO"
R=$(mkfix sym)
ln -sf "$R/tools/git_hook_commit-msg.sh" "$R/.git/hooks/commit-msg"
check "exit 0" "0" "$(run "$R")"
check_log "  symlinkként ismeri fel" "symlink" "$R/out.log"

echo
echo "2. Bitre azonos másolat → GO, de kimondja, hogy másolat"
R=$(mkfix copy)
cp "$R/tools/git_hook_commit-msg.sh" "$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg"
check "exit 0" "0" "$(run "$R")"
check_log "  figyelmeztet a driftre" "A másolat driftel" "$R/out.log"

echo
echo "3. Elavult másolat → NO-GO"
# Ez a valódi #82: a fájl ott van, futtatható, aláír, 0-val tér vissza — csak
# nem azt számolja, amit a repó kiad.
R=$(mkfix stale)
sed 's|cic-tree-manifest/v3|cic-tree-manifest/v1-REGI|' \
    "$R/tools/git_hook_commit-msg.sh" > "$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi az eltérést" "MÁS blokkot ad" "$R/out.log"
check_log "  és megmutatja mindkettőt" "cic-tree-manifest/v1-REGI" "$R/out.log"

echo
echo "4. Nincs hook → exit 2, külön kód"
# Friss klón és a CI is ilyen. Nem hiba, de nem is rendben: az itt készülő
# commitok aláíratlanok lennének. Ha ez 0 lenne, a checker azt mondaná, hogy
# minden rendben egy olyan gépen, ahol semmi nem ír alá.
R=$(mkfix nohook)
check "exit 2" "2" "$(run "$R")"
check_log "  kimondja, mi a következménye" "aláíratlanok lennének" "$R/out.log"

echo
echo "5. Nem futtatható hook → NO-GO"
# A git némán átugorja: a commit létrejön, aláírás nélkül.
R=$(mkfix noexec)
cp "$R/tools/git_hook_commit-msg.sh" "$R/.git/hooks/commit-msg"
chmod -x "$R/.git/hooks/commit-msg"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi a néma átugrást" "némán átugorja" "$R/out.log"

echo
echo "6. Wrapper, ami a kiadottat hívja → GO"
# Legitim minta, és a tartalom-összehasonlítás elutasítaná. Ezért viselkedési
# a döntő próba.
R=$(mkfix wrapper)
cat > "$R/.git/hooks/commit-msg" <<W
#!/usr/bin/env bash
# megosztott dispatcher, ami a repó saját signerét hívja
exec bash "$R/tools/git_hook_commit-msg.sh" "\$1"
W
chmod +x "$R/.git/hooks/commit-msg"
check "exit 0" "0" "$(run "$R")"
check_log "  a viselkedés dönt" "ugyanazt a blokkot adja" "$R/out.log"

echo
echo "7. Wrapper, ami MÁST hív → NO-GO"
R=$(mkfix wrongwrap)
sed 's|cic-tree-manifest/v3|cic-tree-manifest/HAMIS|' \
    "$R/tools/git_hook_commit-msg.sh" > "$R/shared/other.sh"
cat > "$R/.git/hooks/commit-msg" <<W
#!/usr/bin/env bash
exec bash "$R/shared/other.sh" "\$1"
W
chmod +x "$R/.git/hooks/commit-msg"
check "exit 1" "1" "$(run "$R")"
check_log "  megnevezi" "cic-tree-manifest/HAMIS" "$R/out.log"

echo
echo "8. Hook, ami 0-val tér vissza, de nem ír alá → NO-GO"
# A legcsendesebb bukás: minden zöld, a commit aláíratlan.
R=$(mkfix silent)
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg"
check "exit 1" "1" "$(run "$R")"
check_log "  kimondja, hogy nem írt blokkot" "nem írt aláírás-blokkot" "$R/out.log"

echo
echo "9. A core.hooksPath-t követi (ez volt a valódi eset)"
# A .git/hooks-ban a JÓ hook van, a hooksPath viszont a rosszra mutat. Egy
# checker, ami a .git/hooks-ot nézi, itt zöldet adna — és pont ezt a hibát
# hagyná át, ami a #82-t okozta.
R=$(mkfix haspath)
ln -sf "$R/tools/git_hook_commit-msg.sh" "$R/.git/hooks/commit-msg"
sed 's|cic-tree-manifest/v3|cic-tree-manifest/MEGOSZTOTT|' \
    "$R/tools/git_hook_commit-msg.sh" > "$R/shared/commit-msg"
chmod +x "$R/shared/commit-msg"
git -C "$R" config core.hooksPath "$R/shared"
check "exit 1 — a hooksPath-beli hook számít" "1" "$(run "$R")"
check_log "  megnevezi a beállítást" "core.hooksPath van beállítva" "$R/out.log"
check_log "  és hogy az init-hooks.sh önmagában kevés" "önmagában nem lesz elég" "$R/out.log"

echo
echo "10. Helyes manifest-CÍMKE, más SZÁMÍTÁS → NO-GO"
# A legveszélyesebb drift, és a mutációs mérés hozta elő: enélkül az esetnélkül
# a checker átengedte volna azt a hookot, ami `cic-tree-manifest/v3`-at ír, de
# nem azt számolja. Pont a v2→v3 átmenetnél áll elő, ha valaki a címkét átírja,
# a számítást nem. A digest-összehasonlítás nélkül ez láthatatlan.
R=$(mkfix label)
sed "/printf 'author: %s/d" "$R/tools/git_hook_commit-msg.sh" > "$R/.git/hooks/commit-msg"
chmod +x "$R/.git/hooks/commit-msg"
check "a címke ugyanaz marad" "1" \
    "$(grep -c 'MANIFEST_VERSION="cic-tree-manifest/v3"' "$R/.git/hooks/commit-msg")"
check "  exit 1" "1" "$(run "$R")"
check_log "  a digest árulja el" "digest = " "$R/out.log"

echo
echo "11. init-hooks.sh: symlinket telepít, és ELLENŐRZI is"
# Eddig telepített és bejelentette, hogy kész. Hogy a telepített hook tényleg a
# kiadott signer-e, azt nem nézte meg — a #82 pont ezért maradt láthatatlan.
R=$(mkfix init)
( cd "$R" && sh tools/init-hooks.sh ) > "$R/init.log" 2>&1
check "exit 0" "0" "$?"
check "  symlinket tett, nem másolatot" "1" \
    "$([ -L "$R/.git/hooks/commit-msg" ] && echo 1 || echo 0)"
check_log "  és le is ellenőrizte" "Verifying the hook actually in effect" "$R/init.log"
check "  a checker utána GO-t ad" "0" "$(run "$R")"

echo
echo "12. init-hooks.sh megtagadja, ha a hooksPath felülírná"
# A valódi #82-környezet. Eddig telepített volna a .git/hooks-ba, jelentette
# volna, hogy kész — és a git továbbra sem azt futtatja.
R=$(mkfix initpath)
mkdir -p "$R/shared"
cp "$R/tools/git_hook_commit-msg.sh" "$R/shared/commit-msg"
chmod +x "$R/shared/commit-msg"
git -C "$R" config core.hooksPath "$R/shared"
( cd "$R" && sh tools/init-hooks.sh ) > "$R/init.log" 2>&1
check "exit 1" "1" "$?"
check "  NEM telepített a .git/hooks-ba" "0" \
    "$([ -e "$R/.git/hooks/commit-msg" ] && echo 1 || echo 0)"
check_log "  megmondja, hogy némán hatástalan lenne" "silently do nothing" "$R/init.log"
check_log "  és megadja a symlink-parancsot" "symlink, not a copy" "$R/init.log"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
