#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# A rebase utáni újraaláírás (#81).
#
# A mért hiba: a `git rebase` nem futtatja újra a commit-msg hookot, a commit
# fája viszont megváltozik. Három commitos ágon mérve, rebase után OK: 0,
# FAIL: 3 — nem részleges hatás, az ág MINDEN commitja ellenőrizhetetlen.
#
# Ez a suite valódi hookot, valódi rebase-t és valódi verifiert használ.

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SRC/git_hook_commit-msg.sh"
POSTHOOK="$SRC/git_hook_post-rewrite.sh"
VERIFY="$SRC/verify-signatures.sh"
RESIGN="$SRC/resign-range.sh"
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
printf 'hvs.SUITE00000000\n' > "$ENVROOT/vault/sign-token"
printf 'SUITE-CA\n'          > "$ENVROOT/vault/server.crt"
openssl ecparam -name prime256v1 -genkey -noout -out "$ENVROOT/keys/key.pem" 2>/dev/null
openssl req -new -x509 -key "$ENVROOT/keys/key.pem" -out "$ENVROOT/keys/cert.pem" \
    -days 2 -subj "/C=HU/O=suite/CN=suite" 2>/dev/null
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
    git -C "$r" config user.email s@s
    git -C "$r" config user.name  "Suite Sandor"
    git -C "$r" config commit.gpgsign false
    git -C "$r" config core.hooksPath "$r/hooks"
    cp "$VERIFY" "$RESIGN" "$SRC/lib-vault-sign.sh" "$r/tools/"
    cat > "$r/hooks/commit-msg" <<HK
#!/usr/bin/env bash
export PATH="$ENVROOT/bin:\$PATH"
export CIC_VAULT_TOKEN_FILE="$ENVROOT/vault/sign-token"
export CIC_VAULT_CA_FILE="$ENVROOT/vault/server.crt"
export VAULT_ADDR="https://vault.invalid:8200"
exec bash "$HOOK" "\$1"
HK
    chmod +x "$r/hooks/commit-msg"
    cp "$POSTHOOK" "$r/hooks/post-rewrite"
    chmod +x "$r/hooks/post-rewrite"
    printf 'alap\n' > "$r/.base"
    # A tools/ másolatokat is commitolni kell: különben a munkafa piszkos, és a
    # resign-range.sh őre MINDEN esetben elsül — a suite a saját fixture-hibáját
    # mérné, nem az újraaláírást.
    git -C "$r" add -A
    git -C "$r" commit -q --no-verify -m "alap"
    git -C "$r" branch -M main
    echo "$r"
}
# <repó> <hány commit az ágon>
branch_with() {
    local r="$1" n="$2" i
    git -C "$r" checkout -q -b feature/x
    for i in $(seq 1 "$n"); do
        printf 'tartalom %s\n' "$i" > "$r/f$i.txt"
        git -C "$r" add "f$i.txt"
        git -C "$r" commit -q -m "feat: $i. commit"
    done
}
move_main() {
    local r="$1"
    git -C "$r" checkout -q main
    printf 'main halad\n' > "$r/mv.txt"; git -C "$r" add mv.txt
    git -C "$r" commit -q --no-verify -m "main halad"
    git -C "$r" checkout -q feature/x
}
# A logok a repón KÍVÜLRE mennek. Ha a repóba írnánk, a munkafa piszkos lenne,
# és a resign-range.sh őre minden esetben elsülne — a suite a saját zaját mérné.
LOG() { echo "$ENVROOT/$(basename "$1").$2.log"; }
gate() { bash "$1/tools/verify-signatures.sh" --range "main..feature/x" >"$(LOG "$1" gate)" 2>&1; echo $?; }
oks()  { grep -c '^  OK'   "$(LOG "$1" gate)"; }
bads() { grep -c '^  FAIL' "$(LOG "$1" gate)"; }

echo "1. A mért hiba: rebase után az ág MINDEN commitja bukik"
R=$(mkrepo defect); branch_with "$R" 3
check "rebase előtt átmegy" "0" "$(gate "$R")"
check "  3 OK" "3" "$(oks "$R")"
move_main "$R"
git -C "$R" rebase -q main 2>/dev/null
check "rebase után bukik" "1" "$(gate "$R")"
check "  0 OK" "0" "$(oks "$R")"
check "  3 FAIL — nem részleges" "3" "$(bads "$R")"

echo
echo "2. resign-range.sh mindet helyreteszi"
( cd "$R" && bash tools/resign-range.sh main ) > "$(LOG "$R" resign)" 2>&1
check "exit 0" "0" "$?"
check "  a kapu átengedi" "0" "$(gate "$R")"
check "  3 OK" "3" "$(oks "$R")"
check_log "  megmondja, hány commitot ír újra" "3 commit" "$(LOG "$R" resign)"

echo
echo "3. Az újraaláírás nem csonkítja a szerző saját --- elválasztóját"
# Egy sima `sed '/^---$/,$d'` levágná az üzenet felét, és a rebase csendben
# megcsonkítaná a történetet. A verifier ugyanezt a szabályt használja.
R=$(mkrepo dashes)
git -C "$R" checkout -q -b feature/x
printf 'x\n' > "$R/x.txt"; git -C "$R" add x.txt
printf 'fejlec\n\n---\n\ntorzs a sajat elvalaszto UTAN\n' > "$ENVROOT/d.msg"
git -C "$R" commit -q -F "$ENVROOT/d.msg"
move_main "$R"
git -C "$R" rebase -q main 2>/dev/null
( cd "$R" && bash tools/resign-range.sh main ) > "$(LOG "$R" resign)" 2>&1
check "a kapu átengedi" "0" "$(gate "$R")"
check "  a törzs megmaradt" "1" \
    "$(git -C "$R" log -1 --format=%B | grep -c 'torzs a sajat elvalaszto UTAN')"
check "  a saját --- is megmaradt" "2" \
    "$(git -C "$R" log -1 --format=%B | grep -c '^---$')"

echo
echo "4. Nincs mit újraaláírni → nem csinál semmit"
R=$(mkrepo empty)
git -C "$R" checkout -q -b feature/x
( cd "$R" && bash tools/resign-range.sh main ) > "$(LOG "$R" resign)" 2>&1
check "exit 0" "0" "$?"
check_log "  kimondja" "nincs mit újraaláírni" "$(LOG "$R" resign)"

echo
echo "5. Piszkos munkafával megtagadja"
# A rebase elmozdítaná a commitokat a nem commitolt változtatások alól.
R=$(mkrepo dirty); branch_with "$R" 1; move_main "$R"
printf 'nem commitolt\n' > "$R/piszok.txt"
git -C "$R" add piszok.txt
( cd "$R" && bash tools/resign-range.sh main ) > "$(LOG "$R" resign)" 2>&1
check "exit 1" "1" "$?"
check_log "  megnevezi az okot" "munkafa nem tiszta" "$(LOG "$R" resign)"

echo
echo "6. Feloldhatatlan upstream → megtagadja"
R=$(mkrepo badup); branch_with "$R" 1
( cd "$R" && bash tools/resign-range.sh nincs-ilyen-ag ) > "$(LOG "$R" resign)" 2>&1
check "exit 1" "1" "$?"
check_log "  megnevezi" "Feloldhatatlan upstream" "$(LOG "$R" resign)"

echo
echo "7. A post-rewrite hook szól a rebase után"
# Enélkül ez CI-ban derül ki, PR nyitás után.
R=$(mkrepo warn); branch_with "$R" 2; move_main "$R"
git -C "$R" rebase main > "$(LOG "$R" rebase)" 2>&1
check_log "figyelmeztet" "elavult aláírásokat hagyott" "$(LOG "$R" rebase)"
check_log "  megmondja a darabszámot" "2 / 2 commit" "$(LOG "$R" rebase)"
check_log "  és a javító parancsot" "resign-range.sh" "$(LOG "$R" rebase)"

echo
echo "8. A post-rewrite HALLGAT, ha nincs baj"
# Egy figyelmeztetés, ami mindig szól, zaj — és a következőt eltakarja.
R=$(mkrepo quiet); branch_with "$R" 2; move_main "$R"
git -C "$R" rebase main > "$(LOG "$R" rebase)" 2>&1
( cd "$R" && bash tools/resign-range.sh main ) >/dev/null 2>&1
# még egy rebase, most már friss aláírásokkal — nincs mit mozgatni
git -C "$R" rebase main > "$(LOG "$R" rebase2)" 2>&1
check "nem figyelmeztet" "0" "$(grep -c 'elavult aláírásokat' "$(LOG "$R" rebase2)")"

echo
echo "9. Sima amend → nem szól (a commit-msg újrafutott)"
R=$(mkrepo amend); branch_with "$R" 1
git -C "$R" commit -q --amend -m "atirt uzenet" > "$(LOG "$R" amend)" 2>&1
check "nem figyelmeztet" "0" "$(grep -c 'elavult aláírásokat' "$(LOG "$R" amend)")"
check "  és a kapu átengedi" "0" "$(gate "$R")"

echo
echo "10. --amend --no-verify → SZÓL"
# A --no-verify kihagyja a commit-msg hookot: az üzenet megváltozik, a blokk
# marad a régi. Az első post-rewrite változat `rebase`-re szűrt, és pont ezt a
# figyelmeztetést nyomta volna el. A mutációs mérés hozta elő: az őr kivétele
# semmit nem buktatott, mert semmi nem mérte.
R=$(mkrepo noverify); branch_with "$R" 1
git -C "$R" commit -q --amend --no-verify -m "atirt, alairas nelkul" \
    > "$(LOG "$R" amend)" 2>&1
check "figyelmeztet" "1" "$(grep -c 'elavult aláírásokat' "$(LOG "$R" amend)")"
check "  a kapu tényleg bukik" "1" "$(gate "$R")"

echo
echo "$pass PASS, $fail FAIL"
[[ "$fail" -eq 0 ]]
