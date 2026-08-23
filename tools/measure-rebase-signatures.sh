#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# measure-rebase-signatures.sh — a #81 állításainak mérése.
#
# NEM teszt-suite, és nem fut a kapuban. A célja, hogy a #81-re adott válasz
# MÉRT alapon álljon — ugyanaz a minta, ami a #41-nél kiderítette, hogy az audit
# hat állításából kettő hamis volt, és a #44-nél azt, hogy két tervezett mezőt
# egyáltalán nem szabad bekötni.
#
# Két állítást mérünk, mindkettőt ÉN írtam a #81-be, egyiket sem mértem:
#
#   1. „a rebase megbuktatja a kaput"  — a gate az origin/<base>..HEAD tartományt
#      verifikálja; tényleg elhasal-e egy valódi rebase után?
#   2. „fast-forward esetben nem bukik" — tényleg nem?
#
# És egy tervezési kérdés, ami a válasz irányát dönti el:
#
#   3. lefut-e a `post-rewrite` hook rebase-nél, és mit kap?
#
# Futtatás:  bash tools/measure-rebase-signatures.sh

set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SRC/git_hook_commit-msg.sh"
VERIFY="$SRC/verify-signatures.sh"

say()     { printf '\n\033[1m%s\033[0m\n' "$1"; }
verdict() { printf '  → %s\n' "$1"; }

ENVROOT=$(mktemp -d); trap 'rm -rf "$ENVROOT"' EXIT
mkdir -p "$ENVROOT/bin" "$ENVROOT/vault" "$ENVROOT/keys"
printf 'hvs.MEASURE000000\n' > "$ENVROOT/vault/sign-token"
printf 'MEASURE-CA\n'        > "$ENVROOT/vault/server.crt"
openssl ecparam -name prime256v1 -genkey -noout -out "$ENVROOT/keys/key.pem" 2>/dev/null
openssl req -new -x509 -key "$ENVROOT/keys/key.pem" -out "$ENVROOT/keys/cert.pem" \
    -days 2 -subj "/C=HU/O=measure/CN=measure" 2>/dev/null
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
    git -C "$r" config user.email m@m
    git -C "$r" config user.name  "Mero Marta"
    git -C "$r" config commit.gpgsign false
    git -C "$r" config core.hooksPath "$r/hooks"
    cp "$VERIFY" "$r/tools/"
    cat > "$r/hooks/commit-msg" <<HK
#!/usr/bin/env bash
export PATH="$ENVROOT/bin:\$PATH"
export CIC_VAULT_TOKEN_FILE="$ENVROOT/vault/sign-token"
export CIC_VAULT_CA_FILE="$ENVROOT/vault/server.crt"
export VAULT_ADDR="https://vault.invalid:8200"
exec bash "$HOOK" "\$1"
HK
    chmod +x "$r/hooks/commit-msg"
    printf 'alap\n' > "$r/.base"
    git -C "$r" add .base
    git -C "$r" commit -q --no-verify -m "alap (aláíratlan)"
    git -C "$r" branch -M main
    echo "$r"
}
gate() { bash "$1/tools/verify-signatures.sh" --range "$2" 2>&1; }

# ── 1. A gate tartománya egy VALÓDI, nem-fast-forward rebase után ───────────
say "1. A kapu egy valódi (nem fast-forward) rebase után"
R=$(mkrepo real)
git -C "$R" checkout -q -b feature/x
printf 'a feature tartalma\n' > "$R/feat.txt"; git -C "$R" add feat.txt
git -C "$R" commit -q -m "feat: az ág commitja"
echo "  az ág commitja aláírva, a main azóta NEM mozdult"
gate "$R" "main..feature/x" > "$R/before.log"
BEFORE=$?
echo "  kapu rebase ELŐTT: exit=$BEFORE"

git -C "$R" checkout -q main
printf 'valami a mainen\n' > "$R/main.txt"; git -C "$R" add main.txt
git -C "$R" commit -q --no-verify -m "a main halad"
git -C "$R" checkout -q feature/x
git -C "$R" rebase -q main 2>/dev/null
echo "  a main elmozdult, az ág rebase-elve"
gate "$R" "main..feature/x" > "$R/after.log"
AFTER=$?
echo "  kapu rebase UTÁN:  exit=$AFTER"
if [[ "$BEFORE" -eq 0 && "$AFTER" -ne 0 ]]; then
    verdict "REPRODUKÁLT — a rebase megbuktatja a kaput"
    grep -m1 'nem erre a commitra\|NEM erre' "$R/after.log" | sed 's/^/     /'
elif [[ "$AFTER" -eq 0 ]]; then
    verdict "NEM reprodukálódik — a kapu a rebase után is átengedi"
else
    verdict "a kapu már ELŐTTE is bukott (exit $BEFORE) — a fixture rossz"
fi

# ── 2. Fast-forward rebase ──────────────────────────────────────────────────
say "2. Fast-forward rebase (a main nem mozdult)"
# Az issue-ban azt írtam, hogy ezért nem bukott eddig. Ezt nem mértem.
R=$(mkrepo ff)
git -C "$R" checkout -q -b feature/y
printf 'y\n' > "$R/y.txt"; git -C "$R" add y.txt
git -C "$R" commit -q -m "feat: y"
TIP_BEFORE=$(git -C "$R" rev-parse HEAD)
git -C "$R" rebase -q main 2>/dev/null
TIP_AFTER=$(git -C "$R" rev-parse HEAD)
echo "  a commit SHA-ja változott? $([ "$TIP_BEFORE" != "$TIP_AFTER" ] && echo IGEN || echo NEM)"
gate "$R" "main..feature/y" > "$R/ff.log"
FF=$?
echo "  kapu: exit=$FF"
[[ "$FF" -eq 0 ]] && verdict "megerősítve — a ff-rebase nem nyúl a commithoz, a kapu átengedi" \
                  || verdict "az állításom HAMIS volt — a ff-rebase is buktat"

# ── 3. Mit kap a post-rewrite hook? ─────────────────────────────────────────
say "3. Lefut-e a post-rewrite rebase-nél, és mit kap?"
R=$(mkrepo pr)
cat > "$R/hooks/post-rewrite" <<PRH
#!/usr/bin/env bash
echo "ARG=\$1" >> "$R/rewrite.log"
cat >> "$R/rewrite.log"
PRH
chmod +x "$R/hooks/post-rewrite"
git -C "$R" checkout -q -b feature/z
printf 'z\n' > "$R/z.txt"; git -C "$R" add z.txt
git -C "$R" commit -q -m "feat: z"
git -C "$R" checkout -q main
printf 'm\n' > "$R/m.txt"; git -C "$R" add m.txt
git -C "$R" commit -q --no-verify -m "main halad"
git -C "$R" checkout -q feature/z
git -C "$R" rebase -q main 2>/dev/null
if [[ -s "$R/rewrite.log" ]]; then
    verdict "lefut, és megkapja az old→new párokat"
    sed 's/^/     /' "$R/rewrite.log"
else
    verdict "NEM fut le — a post-rewrite alapú újraaláírás nem járható"
fi

# ── 4. Újra tud-e írni a post-rewrite ugyanabban a rebase-ben? ──────────────
say "4. Tud-e a post-rewrite ÚJRA aláírni, recursion nélkül?"
# Ez dönti el, hogy a #81 1. opciója (post-rewrite re-sign) egyáltalán él-e.
R=$(mkrepo resign)
cat > "$R/hooks/post-rewrite" <<PRH
#!/usr/bin/env bash
# az utolsó rewritten commit újraaláírása amenddel
[ -f "$R/.resigning" ] && exit 0
touch "$R/.resigning"
export PATH="$ENVROOT/bin:\$PATH"
export CIC_VAULT_TOKEN_FILE="$ENVROOT/vault/sign-token"
export CIC_VAULT_CA_FILE="$ENVROOT/vault/server.crt"
export VAULT_ADDR="https://vault.invalid:8200"
git log -1 --format=%B | sed '/^---\$/,\$d' > "$R/re.msg"
git commit -q --amend -F "$R/re.msg" 2>>"$R/resign.err"
rm -f "$R/.resigning"
PRH
chmod +x "$R/hooks/post-rewrite"
git -C "$R" checkout -q -b feature/w
printf 'w\n' > "$R/w.txt"; git -C "$R" add w.txt
git -C "$R" commit -q -m "feat: w"
git -C "$R" checkout -q main
printf 'mm\n' > "$R/mm.txt"; git -C "$R" add mm.txt
git -C "$R" commit -q --no-verify -m "main halad"
git -C "$R" checkout -q feature/w
git -C "$R" rebase -q main 2>/dev/null
gate "$R" "main..feature/w" > "$R/resign.log"
RS=$?
echo "  kapu az újraaláírás után: exit=$RS"
sed -n '2,4p' "$R/resign.log" | sed 's/^/     /'
[[ "$RS" -eq 0 ]] && verdict "JÁRHATÓ — a post-rewrite újraaláírás átviszi a kaput" \
                 || verdict "így NEM elég — nézd meg a fenti okot"

# ── 5. Több commit: az amend csak a HEAD-et javítja ────────────────────────
say "5. Három commit rebase-elve — mennyi marad ellenőrizhető?"
# A 4. eset EGY commitot írt újra. A rebase N-et ír át; egy amend a HEAD-en
# csak az utolsót javítja. Ha ezt nem mérem, egy olyan megoldást terveznék,
# ami a demón működik és a valóságban nem.
R=$(mkrepo multi)
git -C "$R" checkout -q -b feature/m
for i in 1 2 3; do
    printf 'tartalom %s\n' "$i" > "$R/f$i.txt"
    git -C "$R" add "f$i.txt"
    git -C "$R" commit -q -m "feat: $i. commit"
done
git -C "$R" checkout -q main
printf 'main\n' > "$R/mv.txt"; git -C "$R" add mv.txt
git -C "$R" commit -q --no-verify -m "main halad"
git -C "$R" checkout -q feature/m
git -C "$R" rebase -q main 2>/dev/null
gate "$R" "main..feature/m" > "$R/multi.log"
echo "  rebase után, újraaláírás NÉLKÜL:"
grep -cE '^  (OK|FAIL)' "$R/multi.log" | sed 's/^/     commit: /'
printf '     OK: %s, FAIL: %s\n' \
    "$(grep -c '^  OK' "$R/multi.log")" "$(grep -c '^  FAIL' "$R/multi.log")"

# Újraaláírás rebase --exec-kel: minden commit után amend, ami újrafuttatja a
# commit-msg hookot.
cat > "$R/resign-head.sh" <<'RS'
#!/usr/bin/env bash
set -e
git log -1 --format=%B | sed '/^---$/,$d' > "$(git rev-parse --git-dir)/resign.msg"
git commit -q --amend -F "$(git rev-parse --git-dir)/resign.msg"
RS
chmod +x "$R/resign-head.sh"
( cd "$R" && git rebase -q main --exec "bash $R/resign-head.sh" ) >"$R/resign2.log" 2>&1
gate "$R" "main..feature/m" > "$R/multi2.log"
MULTI=$?
printf '  újraaláírás UTÁN — OK: %s, FAIL: %s (exit %s)\n' \
    "$(grep -c '^  OK' "$R/multi2.log")" "$(grep -c '^  FAIL' "$R/multi2.log")" "$MULTI"
[[ "$MULTI" -eq 0 ]] && verdict "a rebase --exec mindhármat újraaláírja" \
                     || verdict "nem elég — nézd meg a $R/multi2.log-ot"
