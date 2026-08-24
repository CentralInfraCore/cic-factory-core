#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# A cic-tag-manifest/v1 aláírt release tag (#44).
#
# A mért hiba: a `--tag` verifikáció eddig a tag NEVÉT, célpontját, taggerét és
# üzenetét semmi nem kötötte -- csak a mögöttes commit aláírását nézte. Ez a
# suite a VALÓDI sign-release-tag.sh-t futtatja valódi `git tag -a`-n (hamis
# Vault-tal), és a VALÓDI verifierrel olvassa vissza.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SRC/git_hook_commit-msg.sh"
SIGNTAG="$SRC/sign-release-tag.sh"
VERIFY="$SRC/verify-signatures.sh"
pass=0; fail=0

check() {
    if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — várt: '$2', kapott: '$3'"; ((fail++)); fi
}
check_log() {
    if grep -qF -- "$2" "$3"; then echo "  PASS  $1"; ((pass++))
    else echo "  FAIL  $1 — nem található: '$2'"; ((fail++)); fi
}

ENVROOT=$(mktemp -d); trap 'rm -rf "$ENVROOT"' EXIT
mkdir -p "$ENVROOT/bin" "$ENVROOT/vault" "$ENVROOT/keys"
printf 'hvs.TAGSUITE0000\n' > "$ENVROOT/vault/sign-token"
printf 'TAG-CA\n'           > "$ENVROOT/vault/server.crt"
openssl ecparam -name prime256v1 -genkey -noout -out "$ENVROOT/keys/key.pem" 2>/dev/null
openssl req -new -x509 -key "$ENVROOT/keys/key.pem" -out "$ENVROOT/keys/cert.pem" \
    -days 2 -subj "/C=HU/O=tagsuite/CN=tagsuite" 2>/dev/null
cat > "$ENVROOT/bin/curl" <<FAKE
#!/usr/bin/env bash
last="\${*: -1}"
payload=""; prev=""
for a in "\$@"; do [ "\$prev" = "-d" ] && payload="\$a"; prev="\$a"; done
case "\$last" in
    *transit/sign*)
        d=\$(printf '%s' "\$payload" | sed -n 's/.*"input": *"\([^"]*\)".*/\1/p')
        printf '%s' "\$d" | base64 -d > "$ENVROOT/keys/d.bin"
        openssl pkeyutl -sign -inkey "$ENVROOT/keys/key.pem" \\
            -in "$ENVROOT/keys/d.bin" -out "$ENVROOT/keys/s.der" 2>/dev/null
        printf '{"data":{"signature":"vault:v1:%s"}}' "\$(base64 -w0 < "$ENVROOT/keys/s.der")"
        ;;
    *data/crt*)
        c=\$(sed ':a;N;\$!ba;s/\n/\\\\n/g' "$ENVROOT/keys/cert.pem")
        printf '{"data":{"data":{"bar":"%s"}}}' "\$c"
        ;;
    *) printf '{}' ;;
esac
FAKE
chmod +x "$ENVROOT/bin/curl"

mkrepo() {   # <név>
    local r="$ENVROOT/$1"
    mkdir -p "$r/hooks" "$r/tools"
    git init -q "$r"
    git -C "$r" config user.email t@t
    git -C "$r" config user.name  "Tag Teszt"
    git -C "$r" config commit.gpgsign false
    git -C "$r" config core.hooksPath "$r/hooks"
    cp "$VERIFY" "$SIGNTAG" "$SRC/lib-vault-sign.sh" "$SRC/lib-tag-manifest.sh" \
       "$HOOK" "$r/tools/"
    cat > "$r/hooks/commit-msg" <<HK
#!/usr/bin/env bash
export PATH="$ENVROOT/bin:\$PATH"
export CIC_VAULT_TOKEN_FILE="$ENVROOT/vault/sign-token"
export CIC_VAULT_CA_FILE="$ENVROOT/vault/server.crt"
export VAULT_ADDR="https://vault.invalid:8200"
exec bash "$r/tools/git_hook_commit-msg.sh" "\$1"
HK
    chmod +x "$r/hooks/commit-msg"
    printf 'alap\n' > "$r/.base"
    git -C "$r" add -A
    git -C "$r" commit -q --no-verify -m "alap"
    echo "$r"
}
env_run() { env PATH="$ENVROOT/bin:$PATH" \
    CIC_VAULT_TOKEN_FILE="$ENVROOT/vault/sign-token" \
    CIC_VAULT_CA_FILE="$ENVROOT/vault/server.crt" \
    VAULT_ADDR="https://vault.invalid:8200" "$@"; }
sign_tag() {   # <repó> <tag-név> <target> <notes>
    ( cd "$1" && env_run bash tools/sign-release-tag.sh "$2" "$3" "$4" ) \
        >"$ENVROOT/$(basename "$1").sign.log" 2>&1
    echo $?
}
verify_tag() { bash "$1/tools/verify-signatures.sh" --tag "$2" >"$ENVROOT/$(basename "$1").verify.log" 2>&1; echo $?; }

printf 'Kiadási jegyzet\n\nTartalom.\n' > "$ENVROOT/notes.txt"

echo "1. Aláírt commit + aláírt tag → teljes GO"
R=$(mkrepo full)
git -C "$R" commit -q --allow-empty -m "signed content"
check "sign_tag exit 0" "0" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt")"
check "  a tag valóban annotált" "tag" "$(git -C "$R" cat-file -t core/@v1)"
check "verify_tag exit 0" "0" "$(verify_tag "$R" core/@v1)"
check_log "  a tag maga is aláírva" "a tag objektum maga is aláírva" "$(ls "$ENVROOT/$(basename "$R").verify.log")"
rm -rf "$R"

echo
echo "2. Aláíratlan commit + aláírt tag → a tartalom-ellenőrzés bukik, összesen NO-GO"
# A tag-szintű aláírás önmagában nem elég -- a mögöttes commitnak is
# aláírtnak kell lennie.
R=$(mkrepo hollow)
printf 'x\n' > "$R/x.txt"; git -C "$R" add x.txt; git -C "$R" commit -q --no-verify -m "nincs alairva"
check "sign_tag exit 0 (a tag maga aláírható)" "0" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt")"
check "verify_tag exit 1" "1" "$(verify_tag "$R" core/@v1)"
check_log "  a tag rész rendben van" "a tag objektum maga is aláírva" "$(ls "$ENVROOT/$(basename "$R").verify.log")"
check_log "  de a tartalom nincs" "nincs aláírás-metaadat" "$(ls "$ENVROOT/$(basename "$R").verify.log")"
rm -rf "$R"

echo
echo "3. Régi, tag-szintű aláírás NÉLKÜLI tag → GO, informálva"
# Kompatibilitás: a v0.2.0/v0.2.1/v0.3.0 mintája. A hiány NEM hiba.
R=$(mkrepo plain)
git -C "$R" commit -q --allow-empty -m "signed content"
git -C "$R" tag -a core/@vplain -m "sima annotalt tag" HEAD
check "verify_tag exit 0" "0" "$(verify_tag "$R" core/@vplain)"
check_log "  informál a hiányról, nem buktat" "a tag objektum maga nincs aláírva" \
    "$(ls "$ENVROOT/$(basename "$R").verify.log")"
rm -rf "$R"

echo
echo "4. Tamper: a tag üzenete módosítva a létrehozás után → NO-GO"
R=$(mkrepo tamper)
git -C "$R" commit -q --allow-empty -m "signed content"
sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt" >/dev/null
git -C "$R" cat-file tag core/@v1 | tail -n +5 > "$ENVROOT/tamper.msg"
sed -i 's/Tartalom\./MANIPULALT/' "$ENVROOT/tamper.msg"
git -C "$R" tag -d core/@v1 >/dev/null
git -C "$R" tag -a core/@v1 HEAD -F "$ENVROOT/tamper.msg"
check "verify_tag exit 1" "1" "$(verify_tag "$R" core/@v1)"
check_log "  megnevezi az okot" "NEM erre a tagre illik" "$ENVROOT/$(basename "$R").verify.log"
rm -rf "$R"

echo
echo "5. Tamper: a tag ÁTMUTAT egy másik commitra, a blokk marad → NO-GO"
R=$(mkrepo retarget)
git -C "$R" commit -q --allow-empty -m "signed content"
FIRST=$(git -C "$R" rev-parse HEAD)
sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt" >/dev/null
git -C "$R" commit -q --allow-empty -m "masodik signed content"
SECOND=$(git -C "$R" rev-parse HEAD)
git -C "$R" cat-file tag core/@v1 > "$ENVROOT/retag.full"
sed "s/^object $FIRST/object $SECOND/" "$ENVROOT/retag.full" | tail -n +5 > "$ENVROOT/retag.msg"
git -C "$R" tag -d core/@v1 >/dev/null
git -C "$R" tag -a core/@v1 "$SECOND" -F "$ENVROOT/retag.msg"
check "a tag tényleg a MÁSODIK commitra mutat" "$SECOND" "$(git -C "$R" rev-list -1 core/@v1)"
check "verify_tag exit 1" "1" "$(verify_tag "$R" core/@v1)"
rm -rf "$R"

echo
echo "6. sign-release-tag.sh megtagadja a már létező tag felülírását"
R=$(mkrepo exists)
git -C "$R" commit -q --allow-empty -m "signed content"
sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt" >/dev/null
check "második hívás exit 1" "1" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/notes.txt")"
check_log "  megnevezi az okot" "A tag már létezik" "$ENVROOT/$(basename "$R").sign.log"
rm -rf "$R"

echo
echo "7. sign-release-tag.sh feloldhatatlan célpontra megtagadja"
R=$(mkrepo badtarget)
check "exit 1" "1" "$(sign_tag "$R" core/@v1 nincs-ilyen-commit "$ENVROOT/notes.txt")"
check_log "  megnevezi" "Nem oldható fel commitra" "$ENVROOT/$(basename "$R").sign.log"
rm -rf "$R"

echo
echo "8. sign-release-tag.sh üres üzenetet megtagad"
R=$(mkrepo emptymsg)
git -C "$R" commit -q --allow-empty -m "signed content"
printf '' > "$ENVROOT/empty.txt"
check "exit 1" "1" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/empty.txt")"
check_log "  megnevezi" "Üres release" "$ENVROOT/$(basename "$R").sign.log"
rm -rf "$R"

echo
echo "9. sign-release-tag.sh megtagadja, ha az üzenet már tartalmaz signing-metadata-t"
R=$(mkrepo already)
git -C "$R" commit -q --allow-empty -m "signed content"
printf 'jegyzet\n\n[signing-metadata]\nkulcsmaradek\n' > "$ENVROOT/dup.txt"
check "exit 1" "1" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/dup.txt")"
check_log "  fail closed, nem tudja eldönteni mi ez" "Fail closed" "$ENVROOT/$(basename "$R").sign.log"
rm -rf "$R"

echo
echo "10. A tagger dátuma nem köti a digestet"
# A commit-hookéval szimmetrikus döntés (SPEC.md): a tagger DÁTUMA nincs kötve,
# csak a személye. Két KÜLÖNBÖZŐ nyers identity-sor (más timestamp, más tz),
# ugyanaz a név és email, normalizálás után ugyanazt a digestet kell adja.
D1=$(bash -c 'source '"$SRC"'/lib-tag-manifest.sh
    t=$(tag_normalize_ident "N <n@n> 1000000000 +0000")
    tag_manifest_digest_v1 t oid "$t" torzs')
D2=$(bash -c 'source '"$SRC"'/lib-tag-manifest.sh
    t=$(tag_normalize_ident "N <n@n> 1900000000 +0500")
    tag_manifest_digest_v1 t oid "$t" torzs')
check "más dátummal is ugyanaz a digest" "$D1" "$D2"
D3=$(bash -c 'source '"$SRC"'/lib-tag-manifest.sh
    t=$(tag_normalize_ident "MAS NEV <n@n> 1000000000 +0000")
    tag_manifest_digest_v1 t oid "$t" torzs')
check "  de más NÉVVEL már más digest" "1" "$([ "$D1" != "$D3" ] && echo 1 || echo 0)"

echo
echo "11. Az üzenet saját --- elválasztója túléli az aláírást és a visszaolvasást"
# Ugyanaz a hibaosztály, ami a resign-range.sh-nál és a commit-hooknál is
# előjött: egy naiv első-'---' vágás csendben csonkítaná a release-jegyzetet.
R=$(mkrepo dashes)
git -C "$R" commit -q --allow-empty -m "signed content"
printf 'fejlec

---

torzs a sajat elvalaszto UTAN
' > "$ENVROOT/dashes.txt"
check "sign_tag exit 0" "0" "$(sign_tag "$R" core/@v1 HEAD "$ENVROOT/dashes.txt")"
check "  a törzs megmaradt a tag üzenetében" "1" \
    "$(git -C "$R" cat-file tag core/@v1 | grep -c 'torzs a sajat elvalaszto UTAN')"
check "  a saját --- is megmaradt" "2" \
    "$(git -C "$R" cat-file tag core/@v1 | grep -c '^---$')"
check "verify_tag exit 0" "0" "$(verify_tag "$R" core/@v1)"
rm -rf "$R"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
