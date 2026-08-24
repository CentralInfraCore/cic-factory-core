#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# post-rewrite — szól, ha egy rebase elavult aláírásokat hagyott maga után (#81).
#
# A `git rebase` nem futtatja újra a commit-msg hookot: a régi aláírás-blokkot
# változatlanul viszi át, miközben a commit FÁJA megváltozik. Mérve, három
# commitos ágon: rebase után MIND A HÁROM ellenőrizhetetlen (OK: 0, FAIL: 3).
#
# Eddig ez a CI-ban derült ki, PR nyitás után. Ez a hook helyben mondja meg,
# közvetlenül a rebase után, amikor a javítás egy parancs.
#
# Ez FIGYELMEZTETÉS, nem kapu: a post-rewrite kilépési kódját a git eldobja, és
# a rebase már megtörtént. Az igazi kapu a CI marad — ez csak előbbre hozza.

set -uo pipefail

# Minden átírásra fut, nem csak rebase-re. Az első változat `rebase`-re szűrt,
# azzal az indokkal, hogy az amend úgyis újrafuttatja a commit-msg hookot. A
# mutációs mérés mutatta meg, hogy ez az őr NEM mérhető — és amikor kiderült,
# miért, az is kiderült, hogy káros: a `git commit --amend --no-verify` NEM
# futtatja le a commit-msg hookot, tehát ott is elavult blokk marad. Az őr pont
# azt a figyelmeztetést nyomta volna el, amiért a hook létezik.
#
# Ha nincs baj, a hook hallgat — a verifikáció dönt, nem a művelet neve.

TOP=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
VERIFY="$TOP/tools/verify-signatures.sh"
[[ -x "$VERIFY" || -f "$VERIFY" ]] || exit 0

# stdin: soronként "<régi sha> <új sha>". Az elsőre és az utolsóra van szükség.
FIRST=""; LAST=""
while read -r _old new _rest; do
    [[ -z "$new" ]] && continue
    [[ -z "$FIRST" ]] && FIRST="$new"
    LAST="$new"
done
[[ -n "$FIRST" ]] || exit 0

RANGE="$FIRST^..$LAST"
git rev-parse --verify -q "$FIRST^" >/dev/null 2>&1 || exit 0

if bash "$VERIFY" --range "$RANGE" >/dev/null 2>&1; then
    exit 0
fi

BAD=$(bash "$VERIFY" --range "$RANGE" 2>/dev/null | grep -c '^  FAIL' || true)
TOTAL=$(git rev-list --count "$RANGE" 2>/dev/null || echo '?')

echo
echo "[!] Az átírás elavult aláírásokat hagyott: $BAD / $TOTAL commit nem verifikál."
echo
echo "    A git nem futtatja újra a commit-msg hookot rebase-nél (és a"
echo "    --no-verify amend sem), a commit tartalma viszont megváltozott —"
echo "    a blokk a RÉGI állapotra szól."
echo
echo "    Javítás:"
echo "      bash tools/resign-range.sh <upstream>"
echo
echo "    Ellenőrzés:"
echo "      bash tools/verify-signatures.sh --range <upstream>..HEAD"
echo
exit 0
