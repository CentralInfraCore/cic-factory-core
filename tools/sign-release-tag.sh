#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# sign-release-tag.sh <tag-név> <target-commit> <üzenet-fájl>
#
# Vault-tal aláírt annotált tag létrehozása (#44).
#
# A git nem ismer "pre-tag" hookot -- a `commit-msg` mintája itt nem
# alkalmazható. Ez a script explicit lépés a `git tag -a` helyett, nem egy
# automatikusan lefutó horog.
#
# Amit a `cic-tag-manifest/v1` köt: a tag NEVÉT, a CÉLPONT commit OID-ját, a
# TAGGER személyét (dátum nélkül -- lásd lib-tag-manifest.sh) és az ÜZENET
# digestjét. Amit NEM köt: a tag objektum saját OID-ját -- az a blokk
# hozzáfűzése UTÁN dől el, önhivatkozás lenne.
#
# Ez a `--tag` verifikációt EGY réteggel erősíti: eddig a verifier a tagen
# KERESZTÜL a mögötte álló, ténylegesen aláírt commitig jutott el (#44, a
# tartalom nélküli merge-lánc feloldása), de magát a tag nevét, taggerét és
# üzenetét semmi nem kötötte. Egy tag, amit ez a script hozott létre, ezt is
# köti -- egy RÉGI, e nélkül készült tag továbbra is verifikál a régi módon,
# csak a tag-szintű kötés hiányzik róla.

set -uo pipefail

WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKDIR" || exit 1

# shellcheck source=lib-vault-sign.sh
source "$WORKDIR/tools/lib-vault-sign.sh"
# shellcheck source=lib-tag-manifest.sh
source "$WORKDIR/tools/lib-tag-manifest.sh"

if [[ $# -ne 3 ]]; then
    echo "Használat: bash tools/sign-release-tag.sh <tag-név> <target-commit> <üzenet-fájl>" >&2
    exit 1
fi
TAG_NAME="$1"
TARGET_REF="$2"
MSG_FILE="$3"

# A tag-nevek nem tetszőleges string-ek a git szemében sem (nincs szóköz,
# nincs '..', nincs vezető '-'), de itt egy szűkebb, saját szabályt is
# alkalmazunk: a repó a `core/@vX.Y.Z` és `repo/<név>` mintát használja.
# Fail closed, nem a git hibaüzenetére bízva.
if [[ ! "$TAG_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._/@-]*$ ]]; then
    echo "[!] Érvénytelen tag-név: $TAG_NAME" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$TAG_NAME" >/dev/null 2>&1; then
    echo "[!] A tag már létezik: $TAG_NAME" >&2
    echo "    A release tagek nem íródnak felül -- töröld explicit git parancsokkal," >&2
    echo "    ha tényleg ezt akarod, és utána futtasd újra ezt a scriptet." >&2
    exit 1
fi
if ! TARGET_OID=$(git rev-parse -q --verify "${TARGET_REF}^{commit}" 2>/dev/null); then
    echo "[!] Nem oldható fel commitra: $TARGET_REF" >&2
    exit 1
fi
if [[ ! -f "$MSG_FILE" ]]; then
    echo "[!] Nincs ilyen üzenet-fájl: $MSG_FILE" >&2
    exit 1
fi
BODY=$(cat "$MSG_FILE")
if [[ -z "$BODY" ]]; then
    echo "[!] Üres release-üzenet." >&2
    exit 1
fi
if grep -qF '[signing-metadata]' <<<"$BODY"; then
    echo "[!] Az üzenet már tartalmaz egy '[signing-metadata]' jelölőt." >&2
    echo "    Fail closed: nem tudni, ez egy korábbi blokk maradéka-e." >&2
    exit 1
fi

TAGGER_RAW=$(git var GIT_COMMITTER_IDENT 2>/dev/null) || {
    echo "[!] Nem határozható meg a tagger identitása (git var GIT_COMMITTER_IDENT)." >&2
    exit 1
}
TAGGER=$(tag_normalize_ident "$TAGGER_RAW")

DIGEST_B64=$(tag_manifest_digest_v1 "$TAG_NAME" "$TARGET_OID" "$TAGGER" "$BODY")

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
if ! vault_setup "$tmpdir"; then
    exit 1
fi
SIGNATURE=$(vault_sign_digest "$DIGEST_B64") || exit 1
CERT=$(vault_fetch_cert) || exit 1

MSG_OUT="$tmpdir/tag.msg"
{
    printf '%s\n' "$BODY"
    echo ""
    echo "---"
    echo "[signing-metadata]"
    echo "key = $KEY_NAME"
    echo "signature = $SIGNATURE"
    echo "hash-algorithm = sha256"
    echo "manifest = cic-tag-manifest/v1"
    echo "digest = $DIGEST_B64"
    echo ""
    echo "[certificate]"
    echo "$CERT"
} > "$MSG_OUT"

git tag -a "$TAG_NAME" "$TARGET_OID" -F "$MSG_OUT"

echo
echo "[*] Létrehozva és aláírva: $TAG_NAME -> $TARGET_OID"
echo "    Ellenőrzés: bash tools/verify-signatures.sh --tag $TAG_NAME"
