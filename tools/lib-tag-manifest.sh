#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# lib-tag-manifest.sh — a cic-tag-manifest/v1 digest, közös a signer és a
# verifier között.
#
# Ugyanaz a fegyelem, mint a lib-vault-sign.sh-nál (#82): egy számítás van,
# ketten hívják -- a `sign-release-tag.sh` a tag LÉTREHOZÁSA előtt (a tag
# objektum még nem létezik), a `verify-signatures.sh` egy MEGLÉVŐ tagről
# visszaolvasva. A két hívónak bitre ugyanazt kell számolnia, különben az
# aláírás soha nem verifikálna.
#
# SOURCE-olandó, nem futtatandó.

set -uo pipefail

# tag_normalize_ident <nyers identity sor>
#
# A "Name <email> <timestamp> <tz>" alakból a timestampet és a tz-t vágja le.
# Ugyanaz a minta, mint a commit-msg hook author/committer kötésénél: a
# tagger DÁTUMA nem kötött, csak a személye -- egy tartalmi változás nélküli
# újra-tagelés (pl. ugyanarra a commitra, ugyanazzal az üzenettel) így nem
# bukna meg emiatt.
tag_normalize_ident() {
    sed 's/ [0-9]* [+-][0-9]*$//' <<<"$1"
}

# tag_manifest_digest_v1 <tag-név> <target commit OID> <normalizált tagger> <üzenet-törzs>
#
# A payload NEM tartalmazza a tag objektum SAJÁT OID-ját -- az a signing
# blokk hozzáfűzése UTÁN dől el (a tag objektum tartalmazza az üzenetet, az
# üzenet tartalmazza a blokkot, a blokk tartalmazza az aláírást -- önhivatkozás
# lenne). Amit köt: melyik NÉVEN, melyik COMMITRA, KI, és milyen ÜZENETTEL.
tag_manifest_digest_v1() {
    local tag="$1" target="$2" tagger="$3" body="$4" of msg_sha
    of=$(git rev-parse --show-object-format 2>/dev/null || echo sha1)
    msg_sha=$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)
    { printf 'cic-tag-manifest/v1\n'
      printf 'object-format: %s\n' "$of"
      printf 'tag: %s\n' "$tag"
      printf 'target: %s\n' "$target"
      printf 'tagger: %s\n' "$tagger"
      printf 'message-sha256: %s\n' "$msg_sha"
    } | openssl dgst -sha256 -binary | openssl base64 -A
}

# tag_strip_signing_block <teljes üzenetszöveg>
#
# Ugyanaz a szabály, mint a verifier és a resign-range.sh commit-üzenet
# vágásánál: az UTOLSÓ olyan '---' sornál vág, amit '[signing-metadata]'
# követ. Egy naiv első-'---' vágás csendben csonkítaná a release-jegyzet
# saját '---' elválasztóját.
tag_strip_signing_block() {
    awk '
        { line[NR] = $0; if ($0 == "---" && cut == 0) start = NR }
        $0 == "[signing-metadata]" && start == NR - 1 { cut = start }
        END { last = (cut ? cut - 1 : NR); for (i = 1; i <= last; i++) print line[i] }
    ' <<<"$1"
}
