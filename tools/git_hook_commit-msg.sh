#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
set -euo pipefail

# Commit message fájl (Git adja paraméterként)
COMMIT_MSG_FILE="$1"

# --- Vault Configuration ---
# A CA/https/token ellenőrzés és a curl-config felépítése közös libben él,
# mert a sign-release-tag.sh ugyanezt csinálja -- két független másolat
# driftelne, ahogy a #82 mérte.
#
# A lib helyét a REPÓ GYÖKERÉHEZ képest keressük, nem a hook-fájl saját
# könyvtárához képest: a hook egy symlinken, wrapperen vagy egy elavult
# másolaton át is meghívódhat (#82 pont ez volt), és attól még a repó SAJÁT
# tools/-ját kell aláírásra használnia, ne azt, ahol a hook-fájl fizikailag
# fekszik.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$REPO_ROOT" ]]; then
    echo "[!] Nem egy git repóban futok — nincs mit aláírni." >&2
    exit 1
fi
# shellcheck source=lib-vault-sign.sh
source "$REPO_ROOT/tools/lib-vault-sign.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

if ! vault_setup "$tmpdir"; then
    exit 1
fi

# ===== Staged tartalom snapshot =====
if ! TREE_ID=$(git write-tree 2>/dev/null); then
  echo "[*] Nothing staged; skipping signing."
  exit 0
fi

# ===== Kanonikus manifest (cic-tree-manifest/v2) =====
#
# Az aláírt payload eddig egy `git archive` + `tar` roundtrip sha256-ja volt.
# Két baja volt, és az egyik mérve:
#
#   1. A git archive a GITLINKET üres könyvtárként írja. Két fa, ami CSAK a
#      submodule commitjában tér el, azonos digestet adott — aláírás-kollízió
#      a repository saját objektummodelljén belül (#38).
#
#   2. A digest a tar kódolásától és a kibontó umaskjától függött, nem a Git
#      objektummodelljétől. A verifier ezért négy umaskot próbál végig.
#
# A v2 manifest a Git fáját írja le közvetlenül: minden bejegyzés mode, típus,
# OID és path — a gitlink is, `commit` típussal. Nincs fájlrendszer az útban,
# tehát nincs umask, nincs tar-formátum, és a submodule sem tűnik el.
#
# Verziózott: a régi aláírások a v1 (tar) úton ellenőrizhetők tovább, a
# verify-signatures.sh mindkettőt tudja.
MANIFEST_VERSION="cic-tree-manifest/v3"
OBJECT_FORMAT=$(git rev-parse --show-object-format 2>/dev/null || echo sha1)

# A v3 a commit KONTEXTUSÁT is beleköti, nem csak a fáját.
#
# Mérve (#44): a v2 aláírás átültethető volt. Egy A repóban készült blokk
# változtatás nélkül átment egy MÁSIK repó MÁSIK commitján, más üzenettel —
# mert csak a fa volt aláírva, és a fa azonos volt.
#
# Amit a hook be tud kötni: a commit OID-t nem, mert az még nem létezik. A
# szerzőt, a committert és az üzenetet igen — és ez zárja az átültetést.
#
# Két kézenfekvő mezőt szándékosan NEM kötünk be, mindkettőt mérés után:
#
#   remote URL — környezeti állapot, nem commit-állapot. Ugyanaz a repó SSH-n és
#   HTTPS-en más URL-t ad, egy mirror harmadikat, egy remote nélküli másolat
#   semmit. Mind legitim, és mind hamis elutasítást kapott volna.
#
#   parents — a hook a commit ELŐTT fut, tehát csak a HEAD-et látja. `--amend`
#   esetén az új commit szülője a HEAD SZÜLŐJE, nem a HEAD: a kötés önmagát
#   utasította volna el, és először pont ezen a commiton bukott el. A `git rebase`
#   pedig nem futtatja újra ezt a hookot (mérve) — a régi blokkot változatlanul
#   viszi át egy ÚJ szülő alá, tehát minden rebase-elt commit ellenőrizhetetlenné
#   vált volna. Ebben a projektben a rebase minden PR előtt kötelező.
AUTHOR="$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed 's/ [0-9]* [+-][0-9]*$//')"
COMMITTER="$(git var GIT_COMMITTER_IDENT 2>/dev/null | sed 's/ [0-9]* [+-][0-9]*$//')"
# Az üzenet a blokk hozzáfűzése ELŐTT.
#
# Két normalizálás kell, és mindkettőt MÉRÉS hozta elő:
#
#   `git stripspace --strip-comments` — a `git commit` szerkesztővel a fájlban
#   `#` kezdetű sorok állnak, amiket a git a hook LEFUTÁSA UTÁN takarít el. A
#   hook azokat is behashelte volna, a verifier már nem látná őket.
#
#   `$( )` — a parancshelyettesítés levágja a záró újsorokat. A merge `MERGE_MSG`
#   fájlja nem újsorral végződik, a `git log %B` kimenete igen: enélkül minden
#   merge commit ellenőrizhetetlen lett volna.
MSG_BODY=$(git stripspace --strip-comments < "$COMMIT_MSG_FILE")
MSG_SHA=$(printf '%s' "$MSG_BODY" | openssl dgst -sha256 -binary | openssl base64 -A)

DIGEST_B64=$( {
    printf '%s\n' "$MANIFEST_VERSION"
    printf 'object-format: %s\n' "$OBJECT_FORMAT"
    printf 'author: %s\n' "$AUTHOR"
    printf 'committer: %s\n' "$COMMITTER"
    printf 'message-sha256: %s\n' "$MSG_SHA"
    printf 'tree: %s\n' "$TREE_ID"
    # LC_ALL=C: a rendezés ne függjön a futtató locale-jától.
    git ls-tree -r -t "$TREE_ID" | LC_ALL=C sort
  } | openssl dgst -sha256 -binary | openssl base64 -A )

# ===== Vault aláírás és tanúsítvány =====
SIGNATURE=$(vault_sign_digest "$DIGEST_B64") || exit 1
CERT=$(vault_fetch_cert) || exit 1

# ===== Metaadat blokk hozzáfűzése =====
{
  echo ""
  echo "---"
  echo "[signing-metadata]"
  echo "key = $KEY_NAME"
  echo "signature = $SIGNATURE"
  echo "hash-algorithm = sha256"
  echo "manifest = $MANIFEST_VERSION"
  echo "digest = $DIGEST_B64"
  echo ""
  echo "[certificate]"
  echo "$CERT"
} >> "$COMMIT_MSG_FILE"

echo "[*] Commit message updated with signing metadata."
