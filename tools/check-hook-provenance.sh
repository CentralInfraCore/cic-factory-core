#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# check-hook-provenance.sh — a HATÁLYOS commit-msg hook az-e, amit a repó kiad?
#
# A mért hiba (#82): a `core.hooksPath` egy repón kívüli megosztott könyvtárra
# mutatott, amiben a signer elavult MÁSOLATA volt — még a tar-alapú v1, manifest
# nélkül. A #38 és a #28 javítása két kiadás óta nem volt a lokális trust
# path-ban, és semmi nem szólt: a hook aláírt, 0-val tért vissza, a commit
# hordozta a blokkot.
#
# Amit ez NEM tesz: nem hasonlít fájlt fájlhoz és kész. Egy wrapper, ami a
# kiadott hookot hívja, legitim — a `tools/git_hook_commit-msg.sh` másolása
# viszont pont az a minta, ami ezt a hibát okozta. Ezért a döntő próba
# VISELKEDÉSI: mindkét hookot lefuttatjuk UGYANAZON a scratch repón, hamis
# Vaulttal, és a kiadott aláírás-blokkot hasonlítjuk össze.
#
# Kilépési kódok:
#   0  a hatályos hook a kiadott signer (symlink, azonos tartalom, vagy azonos
#      blokkot ad ugyanarra a bemenetre)
#   1  van hatályos hook, de NEM a kiadott signer — vagy nem futtatható, vagy a
#      próba nem hajtható végre (fail closed)
#   2  nincs hatályos commit-msg hook — friss klón vagy CI; itt a commitok
#      aláíratlanok lennének. Nem hiba, de nem is rendben.

set -uo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKDIR" || exit 1

SHIPPED="$WORKDIR/tools/git_hook_commit-msg.sh"

if [[ ! -f "$SHIPPED" ]]; then
    echo "check-hook-provenance: NO-GO — a kiadott signer nincs meg: $SHIPPED"
    exit 1
fi

# A git maga oldja fel a precedenciát: a --git-path hooks figyelembe veszi a
# core.hooksPath-t. Mérve, nem feltételezve — ezért nem építjük újra kézzel.
HOOKDIR=$(git rev-parse --git-path hooks 2>/dev/null) || HOOKDIR=""
HOOK="$HOOKDIR/commit-msg"
CONFIGURED=$(git config --get core.hooksPath 2>/dev/null || true)

echo "hatályos hook-könyvtár: $HOOKDIR"
[[ -n "$CONFIGURED" ]] && echo "  (core.hooksPath van beállítva: $CONFIGURED)"

if [[ ! -e "$HOOK" ]]; then
    echo "check-hook-provenance: NINCS HOOK — $HOOK nem létezik"
    echo "  Az itt készülő commitok aláíratlanok lennének."
    echo "  Telepítés: bash tools/init-hooks.sh"
    exit 2
fi
# A --git-path RELATÍV utat ad, ha a hooksPath nincs beállítva (.git/hooks). A
# viselkedési próba máshova cd-zik, ott a relatív út nem létezik. Élesben ez
# nem látszott, mert az ottani core.hooksPath abszolút — a fixture-ök fogták meg.
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"

if [[ ! -x "$HOOK" ]]; then
    echo "check-hook-provenance: NO-GO — $HOOK nem futtatható"
    echo "  A git némán átugorja: a commit létrejön, aláírás nélkül."
    exit 1
fi

# ── 1. azonosság: symlink a kiadott signerre ───────────────────────────────
if [[ "$(readlink -f "$HOOK" 2>/dev/null)" == "$(readlink -f "$SHIPPED")" ]]; then
    echo "  OK — a hatályos hook a kiadott signerre mutat (symlink)"
    echo
    echo "check-hook-provenance: GO"
    exit 0
fi

# ── 2. azonos tartalom ─────────────────────────────────────────────────────
if cmp -s "$HOOK" "$SHIPPED"; then
    echo "  OK — a hatályos hook tartalma azonos a kiadottal"
    echo "  Megjegyzés: ez MÁSOLAT. A másolat driftel — ez okozta a #82-t."
    echo "  A symlink (tools/init-hooks.sh) nem tud elavulni."
    echo
    echo "check-hook-provenance: GO"
    exit 0
fi

# ── 3. viselkedés: ugyanazt a blokkot adja-e ugyanarra a bemenetre? ────────
# Idáig csak az jutott el, ami se nem symlink, se nem azonos másolat. Lehet
# legitim wrapper, és lehet elavult másolat — a különbséget csak a futtatás
# mondja meg.
echo "  a hatályos hook se nem symlink, se nem azonos másolat — viselkedési próba"

PROBE=$(mktemp -d) || { echo "check-hook-provenance: NO-GO — nincs temp"; exit 1; }
trap 'rm -rf "$PROBE"' EXIT
mkdir -p "$PROBE/bin" "$PROBE/vault"
printf 'hvs.PROBE0000000000\n' > "$PROBE/vault/sign-token"
printf 'PROBE-CA\n'            > "$PROBE/vault/server.crt"
# Determinisztikus hamis Vault: nem ír alá igaziból, konstans választ ad. Így a
# blokkban a `digest` az EGYETLEN mező, ami a manifest-számítástól függ.
cat > "$PROBE/bin/curl" <<'FAKE'
#!/usr/bin/env bash
last="${*: -1}"
case "$last" in
    *transit/sign*) printf '{"data":{"signature":"vault:v1:PROBE"}}' ;;
    *data/crt*)     printf '{"data":{"data":{"bar":"-----BEGIN CERTIFICATE-----\\nPROBE\\n-----END CERTIFICATE-----"}}}' ;;
    *)              printf '{}' ;;
esac
FAKE
chmod +x "$PROBE/bin/curl"

# A két futásnak BITRE azonos bemenetet kell kapnia: azonos fa, azonos üzenet,
# azonos szerző és committer. Enélkül a v3 manifest amúgy is más digestet adna,
# és a próba a saját zajára mondana NO-GO-t.
probe_run() {   # <hook> <kimenet>
    local hook="$1" out="$2" r="$PROBE/run$3"
    mkdir -p "$r"
    git -C "$r" init -q
    git -C "$r" config user.email probe@invalid
    git -C "$r" config user.name  "Provenance Probe"
    printf 'proba tartalom\n' > "$r/f.txt"
    git -C "$r" add f.txt
    printf 'proba uzenet\n' > "$r/msg.txt"
    ( cd "$r" && env PATH="$PROBE/bin:$PATH" \
        GIT_AUTHOR_NAME="Provenance Probe"    GIT_AUTHOR_EMAIL=probe@invalid \
        GIT_COMMITTER_NAME="Provenance Probe" GIT_COMMITTER_EMAIL=probe@invalid \
        CIC_VAULT_TOKEN_FILE="$PROBE/vault/sign-token" \
        CIC_VAULT_CA_FILE="$PROBE/vault/server.crt" \
        VAULT_ADDR="https://vault.invalid:8200" \
        bash "$hook" "$r/msg.txt" ) >"$out.log" 2>&1
    local rc=$?
    grep -E '^(manifest|digest) = ' "$r/msg.txt" 2>/dev/null | LC_ALL=C sort > "$out"
    return $rc
}

probe_run "$SHIPPED" "$PROBE/shipped" A
SHIPPED_RC=$?
probe_run "$HOOK"    "$PROBE/effective" B
EFF_RC=$?

if [[ "$SHIPPED_RC" -ne 0 ]]; then
    echo "check-hook-provenance: NO-GO — a KIADOTT signer nem futott le a próbán (exit $SHIPPED_RC)"
    echo "  Ez a checker hibája, nem a hatályos hooké. A próba kimenete:"
    sed 's/^/    /' "$PROBE/shipped.log" | head -5
    exit 1
fi
if [[ "$EFF_RC" -ne 0 ]]; then
    echo "check-hook-provenance: NO-GO — a hatályos hook nem futott le a próbán (exit $EFF_RC)"
    echo "  Fail closed: ha nem hajtható végre, nem mondjuk rá, hogy rendben van."
    sed 's/^/    /' "$PROBE/effective.log" | head -5
    exit 1
fi
if [[ ! -s "$PROBE/effective" ]]; then
    echo "check-hook-provenance: NO-GO — a hatályos hook nem írt aláírás-blokkot"
    exit 1
fi

if diff -q "$PROBE/shipped" "$PROBE/effective" >/dev/null; then
    echo "  OK — ugyanarra a bemenetre ugyanazt a blokkot adja, mint a kiadott"
    echo "$(sed 's/^/    /' "$PROBE/shipped")"
    echo
    echo "check-hook-provenance: GO"
    exit 0
fi

echo "  a hatályos hook MÁS blokkot ad, mint a kiadott:"
echo "    kiadott:"
sed 's/^/      /' "$PROBE/shipped"
echo "    hatályos:"
sed 's/^/      /' "$PROBE/effective"
echo
echo "  A hatályos hook nem az, amit ez a repó kiad. Ha másolat, driftelt."
echo "  Javítás: bash tools/init-hooks.sh (symlink, nem másolat)"
[[ -n "$CONFIGURED" ]] && \
    echo "  FIGYELEM: a core.hooksPath ($CONFIGURED) felülírja a .git/hooks-ot," && \
    echo "  tehát az init-hooks.sh önmagában nem lesz elég — vagy szüntesd meg a" && \
    echo "  beállítást, vagy a megosztott könyvtárban legyen symlink a kiadottra."
echo
echo "check-hook-provenance: NO-GO"
exit 1
