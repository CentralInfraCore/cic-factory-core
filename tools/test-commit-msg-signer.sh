#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# git_hook_commit-msg.sh — a signer az a pont, ahol a provenance keletkezik.
# Korábban CA hiányában figyelmeztetett, `curl -k`-ra váltott, és a Vault
# tokent így küldte el. Aki az útvonalon van, elkaphatta a tokent, saját
# aláírás-választ és saját tanúsítványt adhatott vissza, utána pedig a
# megszerzett tokennel tetszőleges digestet írathatott alá.
#
# A token ráadásul `-H` argumentumként utazott, tehát ugyanazon felhasználó
# bármely folyamata kiolvashatta a process-listából, és `export`-tal minden
# gyermek is megörökölte.
#
# A curl itt hamis: rögzíti, mit kapott, és előre megírt választ ad. Így
# mérhető, hogy mi NEM szerepel az argv-ben — ami a lényeg.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SRC/git_hook_commit-msg.sh"
TOKEN="hvs.TESTTOKEN0123456789"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}

# Git repo + staged tartalom, hogy a `git write-tree` működjön.
mkenv() {
    local r; r=$(mktemp -d)
    mkdir -p "$r/repo" "$r/vault" "$r/bin"
    git -C "$r/repo" init -q
    git -C "$r/repo" config user.email t@t
    git -C "$r/repo" config user.name t
    echo "tartalom" > "$r/repo/f.txt"
    git -C "$r/repo" add f.txt
    printf '%s' "$TOKEN" > "$r/vault/sign-token"
    printf 'FAKE-CA\n'  > "$r/vault/server.crt"
    printf '# Teszt commit\n' > "$r/msg.txt"

    # A hamis curl kiírja az argv-t és a --config fájl tartalmát, majd a
    # kért endpointhoz tartozó választ adja.
    cat > "$r/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FAKE_CURL_ARGV"
for i in "$@"; do
    case "$prev" in --config|-K) cat "$i" >> "$FAKE_CURL_CFG"; printf '\n' >> "$FAKE_CURL_CFG" ;; esac
    prev="$i"
done
if [ -n "${FAKE_CURL_FAIL:-}" ]; then exit 7; fi
last="${*: -1}"
case "$last" in
    *transit/sign*) printf '{"data":{"signature":"vault:v1:TESTSIG"}}' ;;
    *data/crt*)     printf '{"data":{"data":{"bar":"-----BEGIN CERTIFICATE-----\\nTEST\\n-----END CERTIFICATE-----"}}}' ;;
    *)              printf '{}' ;;
esac
FAKE
    chmod +x "$r/bin/curl"
    echo "$r"
}

run() {
    local r="$1"; shift
    ( cd "$r/repo" && env PATH="$r/bin:$PATH" \
        FAKE_CURL_ARGV="$r/argv.txt" FAKE_CURL_CFG="$r/cfg.txt" \
        CIC_VAULT_TOKEN_FILE="$r/vault/sign-token" \
        CIC_VAULT_CA_FILE="$r/vault/server.crt" \
        VAULT_ADDR="https://vault.invalid:8200" \
        "$@" bash "$HOOK" "$r/msg.txt" >"$r/out.log" 2>&1 )
    echo $?
}
signed() { grep -qF 'signing-metadata' "$1/msg.txt" && echo yes || echo no; }

echo "0. Ép környezet → aláír"
R=$(mkenv)
check "exit 0" "0" "$(run "$R")"
check "  a metaadat blokk odakerült" "yes" "$(signed "$R")"
check "  az aláírás a Vault válaszából jön" "1" "$(grep -c 'vault:v1:TESTSIG' "$R/msg.txt")"
rm -rf "$R"

echo
echo "A token nem kerül a parancssorba"
R=$(mkenv); run "$R" >/dev/null
check "argv nem tartalmazza a tokent" "0" "$(grep -c "$TOKEN" "$R/argv.txt" || true)"
check "  argv nem tartalmaz X-Vault-Token fejlécet" "0" "$(grep -c 'X-Vault-Token' "$R/argv.txt" || true)"
check "  a config fájlban viszont ott van" "1" "$(sort -u "$R/cfg.txt" | grep -c "X-Vault-Token: $TOKEN")"
rm -rf "$R"

echo
echo "A curl-konfig azt kapja, amit kell"
R=$(mkenv); run "$R" >/dev/null
check "cacert a konfigban" "1" "$(sort -u "$R/cfg.txt" | grep -c 'cacert = ')"
check "  max-time a konfigban" "1" "$(sort -u "$R/cfg.txt" | grep -c 'max-time = 20')"
check "  a curl kétszer futott (sign + cert)" "2" "$(grep -c -- '--config' "$R/argv.txt")"
check "  nincs -k / --insecure sehol" "0" "$(grep -cE '(^|[[:space:]])(-k|--insecure|insecure)' "$R/argv.txt" "$R/cfg.txt" | awk -F: '{s+=$2} END{print s+0}')"
rm -rf "$R"

echo
echo "Hiányzó CA → a commit megáll (ez volt a -k ág)"
R=$(mkenv); rm "$R/vault/server.crt"
check "exit 1" "1" "$(run "$R")"
check "  NEM ír aláírást" "no" "$(signed "$R")"
check "  a curl meg sem szólalt" "0" "$([ -f "$R/argv.txt" ] && echo 1 || echo 0)"
check "  megmondja melyik fájl hiányzik" "1" "$(grep -c 'CA certificate not found' "$R/out.log")"
rm -rf "$R"

echo
echo "Nem-https VAULT_ADDR → a token el sem indul"
R=$(mkenv)
rc=$( cd "$R/repo" && env PATH="$R/bin:$PATH" \
      FAKE_CURL_ARGV="$R/argv.txt" FAKE_CURL_CFG="$R/cfg.txt" \
      CIC_VAULT_TOKEN_FILE="$R/vault/sign-token" \
      CIC_VAULT_CA_FILE="$R/vault/server.crt" \
      VAULT_ADDR="http://vault.invalid:8200" \
      bash "$HOOK" "$R/msg.txt" >"$R/out.log" 2>&1; echo $? )
check "exit 1" "1" "$rc"
check "  NEM ír aláírást" "no" "$(signed "$R")"
check "  a curl meg sem szólalt" "0" "$([ -f "$R/argv.txt" ] && echo 1 || echo 0)"
rm -rf "$R"

echo
echo "Hiányzó token-fájl → megáll"
R=$(mkenv); rm "$R/vault/sign-token"
check "exit 1" "1" "$(run "$R")"
check "  NEM ír aláírást" "no" "$(signed "$R")"
rm -rf "$R"

echo
echo "A curl elszáll (timeout / TLS) → fail closed"
R=$(mkenv)
check "exit 1" "1" "$(run "$R" FAKE_CURL_FAIL=1)"
check "  NEM ír aláírást" "no" "$(signed "$R")"
check "  megnevezi az okot" "1" "$(grep -c 'timeout\|TLS' "$R/out.log")"
rm -rf "$R"

echo
echo "XDG_RUNTIME_DIR nélkül értelmes hibát ad, nem 'unbound variable'"
R=$(mkenv)
rc=$( cd "$R/repo" && env -i PATH="$R/bin:$PATH" HOME="$R" \
      VAULT_ADDR="https://vault.invalid:8200" \
      bash "$HOOK" "$R/msg.txt" >"$R/out.log" 2>&1; echo $? )
check "exit 1" "1" "$rc"
check "  nem unbound variable" "0" "$(grep -c 'unbound variable' "$R/out.log")"
check "  a hiányzó CA-t nevezi meg" "1" "$(grep -c 'CA certificate not found' "$R/out.log")"
rm -rf "$R"

echo
echo "A hook a manifest-verziót és egy ép digestet ír a blokkba"
# FIGYELEM: ez a szakasz korábban azt a CÍMET viselte, hogy "a hook és a
# verifier ugyanazt a manifestet számolja" — és a verifiert EL SEM INDÍTOTTA.
# Csak a manifest-sort és a digest ALAKJÁT nézte. Egy hook, ami helyes alakú,
# de rossz digestet ír, átment volna rajta.
#
# A valódi round-tripet (valódi hook → valódi `git commit` → valódi verifier)
# a tools/test-proof-binding.sh méri. Itt csak az marad, ami tényleg itt van:
# a blokk alakja.
R=$(mkenv)
run "$R" >/dev/null
check "a hook manifest-verziót ír a blokkba" "1" \
    "$(grep -c 'manifest = cic-tree-manifest/v3' "$R/msg.txt")"
check "  a digest base64-sha256 alakú" "1" \
    "$(grep -oP '^digest = \K\S+' "$R/msg.txt" | head -1 | base64 -d 2>/dev/null | wc -c | grep -c '^32$')"
check "  a commit-kontextust is behasheli" "1" \
    "$(grep -c "printf 'message-sha256:" "$HOOK")"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
