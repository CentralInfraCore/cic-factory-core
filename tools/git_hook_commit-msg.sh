#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
set -euo pipefail

# Commit message fájl (Git adja paraméterként)
COMMIT_MSG_FILE="$1"

# --- Vault Configuration ---
# Use environment variables for paths if they exist, otherwise use local defaults.
# This allows the script to run both locally and inside a Docker container.
# The default is spelled out rather than interpolating $XDG_RUNTIME_DIR directly:
# under `set -u` an unset XDG_RUNTIME_DIR aborted the hook with "unbound
# variable" before it could say what was actually missing.
XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
VAULT_TOKEN_FILE="${CIC_VAULT_TOKEN_FILE:-${XDG_RUNTIME_DIR}/vault/sign-token}"
VAULT_CA_CERT_FILE="${CIC_VAULT_CA_FILE:-${XDG_RUNTIME_DIR}/vault/server.crt}"
VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18200}" # Default to local dev server
VAULT_MAX_TIME="${CIC_VAULT_MAX_TIME:-20}"
KEY_NAME="cic-my-sign-key"

# --- TLS trust is not optional ---
# This used to warn and fall back to `curl -k`, then send the Vault token down
# the unverified connection anyway. That is not a confidentiality nit: this is
# the point where provenance is established. Anyone in path could take the
# token, return a signing response of their choosing, return a certificate of
# their choosing, and afterwards sign any digest they liked with the captured
# token. A missing CA has to stop the commit, not annotate it.
if [ ! -f "$VAULT_CA_CERT_FILE" ]; then
    echo "[!] Vault CA certificate not found: $VAULT_CA_CERT_FILE" >&2
    echo "    A commit aláírása TLS-ellenőrzés nélkül nem történhet meg." >&2
    echo "    Add meg a CA-t (CIC_VAULT_CA_FILE), vagy állítsd elő ide." >&2
    exit 1
fi
case "$VAULT_ADDR" in
    https://*) ;;
    *) echo "[!] VAULT_ADDR nem https: $VAULT_ADDR" >&2
       echo "    A signing tokent nem küldjük titkosítatlan csatornán." >&2
       exit 1 ;;
esac

# --- Load Vault Token from file ---
if [ ! -f "$VAULT_TOKEN_FILE" ]; then
    echo "[!] Vault token file not found at $VAULT_TOKEN_FILE" >&2
    exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# The token used to travel as a `-H` argument, which puts it in the process
# list for every process of the same user, and was `export`ed on top of that,
# so every child inherited it. A curl config file keeps it out of both: it is
# 0600, inside a directory that goes away with the hook.
CURL_CFG="$tmpdir/curl.cfg"
( umask 077; : > "$CURL_CFG" )
{
  printf 'silent\n'
  printf 'cacert = "%s"\n' "$VAULT_CA_CERT_FILE"
  printf 'max-time = %s\n' "$VAULT_MAX_TIME"
  printf 'header = "X-Vault-Token: %s"\n' "$(cat "$VAULT_TOKEN_FILE")"
} >> "$CURL_CFG"

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

# ===== Vault aláírás =====
SIGNATURE_RESPONSE=$(curl --config "$CURL_CFG" \
  -X POST \
  -d "{\"input\": \"${DIGEST_B64}\", \"prehashed\": true, \"hash_algorithm\": \"sha2-256\"}" \
  "${VAULT_ADDR}/v1/transit/sign/${KEY_NAME}") || {
    echo "[!] A Vault signing endpoint nem válaszolt (timeout ${VAULT_MAX_TIME}s vagy TLS-hiba)." >&2
    exit 1
}

SIGNATURE=$(echo "${SIGNATURE_RESPONSE}" | jq -r '.data.signature')

if [[ -z "${SIGNATURE:-}" || "$SIGNATURE" == "null" ]]; then
  echo "[!] Signing failed. Vault response: ${SIGNATURE_RESPONSE}"
  exit 1
fi

# ===== Tanúsítvány beolvasás =====
# KV v2 mount at KEY_NAME, secret 'crt'
CERT_RESPONSE=$(curl --config "$CURL_CFG" \
  "${VAULT_ADDR}/v1/${KEY_NAME}/data/crt") || {
    echo "[!] A tanúsítvány nem kérhető le (timeout ${VAULT_MAX_TIME}s vagy TLS-hiba)." >&2
    exit 1
}

CERT=$(echo "${CERT_RESPONSE}" | jq -r '.data.data.bar') # Assuming PEM data is under 'bar' key

if [[ -z "${CERT:-}" || "$CERT" == "null" ]]; then
  echo "[!] CERT get failed. Vault response: ${CERT_RESPONSE}"
  exit 1
fi

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
