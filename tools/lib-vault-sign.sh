#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# lib-vault-sign.sh — a Vault Transit-hívás megosztott alapja.
#
# Kivonva a `git_hook_commit-msg.sh`-ból, hogy a `sign-release-tag.sh` ne
# implementálja újra ugyanazt. A #82 pont ezt a hibaosztályt mérte: két
# független másolat driftel, és a drift néma. Egy aláíró van, ketten hívják.
#
# Ez a fájl SOURCE-olandó, nem futtatandó. A hívó felelőssége a $CIC_VAULT_*
# és $VAULT_ADDR környezeti változók beállítása a `vault_setup` hívása előtt.
#
# Exportált függvények, ebben a sorrendben hívandók:
#   vault_setup <tmpdir>          -- ellenőriz (CA, https, token), felépíti a
#                                     curl configot $tmpdir alatt. Fail closed:
#                                     exit 1, ha bármi hiányzik vagy nem https.
#   vault_sign_digest <digest_b64> -- aláír, a signature-t írja stdoutra
#   vault_fetch_cert               -- lekéri a tanúsítványt, PEM-et ír stdoutra

set -uo pipefail

vault_setup() {
    local tmpdir="$1"

    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}"
    VAULT_TOKEN_FILE="${CIC_VAULT_TOKEN_FILE:-${XDG_RUNTIME_DIR}/vault/sign-token}"
    VAULT_CA_CERT_FILE="${CIC_VAULT_CA_FILE:-${XDG_RUNTIME_DIR}/vault/server.crt}"
    VAULT_ADDR="${VAULT_ADDR:-https://127.0.0.1:18200}"
    VAULT_MAX_TIME="${CIC_VAULT_MAX_TIME:-20}"
    KEY_NAME="cic-my-sign-key"

    # TLS trust nem opcionális. Ez a pont, ahol a provenance keletkezik --
    # `curl -k`-ra váltás a tokent egy megbízhatatlan csatornán küldené el
    # annak, aki épp az útban van (#28).
    if [ ! -f "$VAULT_CA_CERT_FILE" ]; then
        echo "[!] Vault CA certificate not found: $VAULT_CA_CERT_FILE" >&2
        echo "    Aláírás TLS-ellenőrzés nélkül nem történhet meg." >&2
        echo "    Add meg a CA-t (CIC_VAULT_CA_FILE), vagy állítsd elő ide." >&2
        return 1
    fi
    case "$VAULT_ADDR" in
        https://*) ;;
        *) echo "[!] VAULT_ADDR nem https: $VAULT_ADDR" >&2
           echo "    A signing tokent nem küldjük titkosítatlan csatornán." >&2
           return 1 ;;
    esac
    if [ ! -f "$VAULT_TOKEN_FILE" ]; then
        echo "[!] Vault token file not found at $VAULT_TOKEN_FILE" >&2
        return 1
    fi

    # A token eddig `-H` argumentumként utazott (process listán látszik minden
    # azonos user alatti folyamatnak), és `export`-álva is volt (minden gyerek
    # örökölte). A curl config file 0600, egy hookonként/híváskor eldobott
    # tmpdiren belül -- egyik útvonalról sem szivárog (#28).
    CURL_CFG="$tmpdir/curl.cfg"
    ( umask 077; : > "$CURL_CFG" )
    {
        printf 'silent\n'
        printf 'cacert = "%s"\n' "$VAULT_CA_CERT_FILE"
        printf 'max-time = %s\n' "$VAULT_MAX_TIME"
        printf 'header = "X-Vault-Token: %s"\n' "$(cat "$VAULT_TOKEN_FILE")"
    } >> "$CURL_CFG"
    return 0
}

vault_sign_digest() {
    local digest_b64="$1" resp sig
    resp=$(curl --config "$CURL_CFG" \
        -X POST \
        -d "{\"input\": \"${digest_b64}\", \"prehashed\": true, \"hash_algorithm\": \"sha2-256\"}" \
        "${VAULT_ADDR}/v1/transit/sign/${KEY_NAME}") || {
        echo "[!] A Vault signing endpoint nem válaszolt (timeout ${VAULT_MAX_TIME}s vagy TLS-hiba)." >&2
        return 1
    }
    sig=$(echo "$resp" | jq -r '.data.signature')
    if [[ -z "${sig:-}" || "$sig" == "null" ]]; then
        echo "[!] Signing failed. Vault response: ${resp}" >&2
        return 1
    fi
    printf '%s' "$sig"
}

vault_fetch_cert() {
    local resp cert
    resp=$(curl --config "$CURL_CFG" \
        "${VAULT_ADDR}/v1/${KEY_NAME}/data/crt") || {
        echo "[!] A tanúsítvány nem kérhető le (timeout ${VAULT_MAX_TIME}s vagy TLS-hiba)." >&2
        return 1
    }
    cert=$(echo "$resp" | jq -r '.data.data.bar')
    if [[ -z "${cert:-}" || "$cert" == "null" ]]; then
        echo "[!] CERT get failed. Vault response: ${resp}" >&2
        return 1
    fi
    printf '%s' "$cert"
}
