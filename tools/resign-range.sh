#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# resign-range.sh [<upstream>] — a rebase után elavult aláírások újraírása.
#
# A mért hiba (#81): a `git rebase` NEM futtatja újra a commit-msg hookot. A
# régi aláírás-blokkot változatlanul viszi át — miközben a commit fája MEGVÁLTOZIK,
# mert az ág mostantól az új alap tartalmát is hordozza. Az aláírás így nem arra
# a fára szól, amin áll.
#
# Mérve, három commitos ágon:
#
#   rebase után, újraaláírás nélkül   OK: 0, FAIL: 3
#   rebase --exec újraaláírással      OK: 3, FAIL: 0
#
# Nem részleges hatás: a rebase-elt ág MINDEN commitja ellenőrizhetetlenné válik.
#
# A mechanizmus: `git rebase <upstream> --exec`, ami minden alkalmazott commit
# UTÁN lefuttat egy amendet ugyanazzal az üzenettel. Az amend újrafuttatja a
# commit-msg hookot, ami friss digestet számol az ÚJ fára.
#
# Ez nem kerüli meg az aláírást és nem gyengíti: minden commit valódi, friss
# Vault-aláírást kap. Amit megkerül, az a `git rebase` azon viselkedése, hogy
# aláírt tartalmat mozgat aláírás nélkül.

set -uo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKDIR" || exit 1

UPSTREAM="${1:-}"
if [[ -z "$UPSTREAM" ]]; then
    UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
fi
if [[ -z "$UPSTREAM" ]]; then
    echo "[!] Nincs megadva upstream, és az ágnak nincs beállítva."
    echo "    Használat: bash tools/resign-range.sh <upstream>"
    echo "    Például:   bash tools/resign-range.sh origin/main"
    exit 1
fi
if ! git rev-parse --verify -q "$UPSTREAM" >/dev/null; then
    echo "[!] Feloldhatatlan upstream: $UPSTREAM"
    exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
    echo "[!] A munkafa nem tiszta. A rebase elmozdítaná a commitokat alatta."
    exit 1
fi

COUNT=$(git rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)
if [[ "$COUNT" -eq 0 ]]; then
    echo "Nincs commit a $UPSTREAM..HEAD tartományban — nincs mit újraaláírni."
    exit 0
fi

echo "Újraaláírás: $COUNT commit a $UPSTREAM..HEAD tartományban"
echo

# Az amendhez az üzenet a signing blokk NÉLKÜL kell. A blokkot az UTOLSÓ olyan
# `---` sornál vágjuk le, amit `[signing-metadata]` követ — ugyanaz a szabály,
# mint a verify-signatures.sh-ban. Egy sima `sed '/^---$/,$d'` levágná a szerző
# saját `---` elválasztóját, és a rebase csendben megcsonkítaná az üzeneteket.
STRIP_AWK='
    { line[NR] = $0; if ($0 == "---" && cut == 0) start = NR }
    $0 == "[signing-metadata]" && start == NR - 1 { cut = start }
    END { last = (cut ? cut - 1 : NR); for (i = 1; i <= last; i++) print line[i] }'

HELPER="$(git rev-parse --git-dir)/cic-resign-head.sh"
cat > "$HELPER" <<HLP
#!/usr/bin/env bash
set -e
MSG="\$(git rev-parse --git-dir)/cic-resign.msg"
git log -1 --format=%B | awk '$STRIP_AWK' > "\$MSG"
git commit -q --amend -F "\$MSG"
rm -f "\$MSG"
HLP
chmod +x "$HELPER"
# shellcheck disable=SC2064
trap "rm -f '$HELPER'" EXIT

if git rebase "$UPSTREAM" --exec "bash '$HELPER'"; then
    echo
    echo "Kész. Ellenőrzés:"
    echo "  bash tools/verify-signatures.sh --range $UPSTREAM..HEAD"
else
    echo
    echo "[!] A rebase megállt. Rendezd a helyzetet, majd:"
    echo "      git rebase --continue   (az újraaláírás magától folytatódik)"
    echo "      git rebase --abort      (és semmi nem változik)"
    exit 1
fi
