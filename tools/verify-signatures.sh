#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
# SPDX-FileCopyrightText: 2025-2026 Sinkó Gábor Zoltán / CentralInfraCore
#
# verify-signatures.sh [--range <A>..<B>] [--tag <name>]
#
# The commit-msg hook writes a Vault signature into every commit message. Until
# now nothing read them back. A signature nobody verifies is a claim, not
# evidence -- which is the one thing this repository is not allowed to ship.
#
# What is checked, per commit in the range:
#
#   non-merge   must carry signing metadata; the recorded digest must equal a
#               fresh tar-of-tree digest; and the ECDSA signature must verify
#               against the certificate embedded in the same message
#
#   merge       GitHub creates these server-side, where no hook runs, so they
#               cannot be signed. Instead they must introduce nothing: the merge
#               tree has to equal one of its parents'. That keeps the real
#               invariant -- every byte in the tree is covered by some signed
#               commit -- without pretending the merge itself is signed. A merge
#               that does introduce content must be signed like any other commit.
#
# Verification is offline. The certificate travels in the commit message, so no
# Vault and no network are needed; the signing token cannot verify anyway (its
# policy grants transit/sign but not transit/verify).
#
# The range is the point. History is not in scope: 33 commits were extracted
# from cic-factory with their signatures removed -- they name the original
# instead -- and seven predate the hook entirely. Those are settled facts, not
# regressions. What must hold is that everything added from here on is covered.
#
# Exit 0 = every commit in range accounted for, exit 1 = at least one is not.

set -uo pipefail

# Every other tool here derives its repository from the script location; this one
# did not, so it silently inspected whatever repository the caller happened to be
# standing in. Its own test suite caught that on the first run.
WORKDIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WORKDIR" || exit 1

RANGE=""
TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --range) RANGE="${2:?--range needs A..B}"; shift 2 ;;
        --tag)   TAG="${2:?--tag needs a name}";   shift 2 ;;
        *) echo "Usage: $0 [--range A..B] [--tag <name>]" >&2; exit 1 ;;
    esac
done

fail=0
ok=0

# `tar -x` applies the umask to the extracted modes, so the digest is a function
# of the tree AND of the umask the signer happened to have. The hook now pins
# 022, but commits signed before that pin carry a digest computed under whatever
# their author had -- 002 on a workstation, 022 on a runner.
#
# So the digest is computed under each plausible umask and any match is accepted.
# This does not weaken the binding: the umask only varies mode bits inside the
# archive, and finding different content that collides is still a SHA-256
# preimage problem. What it does mean is that a match proves the tree, not the
# umask.
UMASKS=(022 002 077 000)

tree_digest() {
    local tree="$1" mask="$2" tmp out
    tmp=$(mktemp -d) || return 1
    out=$( umask "$mask"
           git archive --format=tar "$tree" | tar -xf - -C "$tmp"
           tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
               -cf - -C "$tmp" . | openssl dgst -sha256 -binary | openssl base64 -A )
    rm -rf "$tmp"
    printf '%s' "$out"
}

# cic-tree-manifest/v2: a Git fáját írja le közvetlenül, minden bejegyzés mode,
# típus, OID és path -- a GITLINK is, `commit` típussal.
#
# A v1 (tar roundtrip) a gitlinket üres könyvtárként vitte: két fa, ami csak a
# submodule commitjában tért el, azonos digestet adott (#38). Nincs benne
# fájlrendszer, tehát umask sincs.
manifest_digest_v2() {
    # A hívó revízió-kifejezést ad (`<sha>^{tree}`); a manifestbe a FELOLDOTT
    # OID tartozik, mert a hook is azt írja (git write-tree).
    local tree; tree=$(git rev-parse "$1" 2>/dev/null) || tree="$1"
    { printf 'cic-tree-manifest/v2\n'
      printf 'object-format: %s\n' "$(git rev-parse --show-object-format 2>/dev/null || echo sha1)"
      printf 'tree: %s\n' "$tree"
      git ls-tree -r -t "$tree" | LC_ALL=C sort
    } | openssl dgst -sha256 -binary | openssl base64 -A
}

# cic-tree-manifest/v3: a fa MELLETT a commit kontextusát is köti.
#
# A v2 aláírás átültethető volt: egy A repóban készült blokk átment egy MÁSIK
# repó MÁSIK commitján, más üzenettel, mert csak a fa volt aláírva (#44).
#
# A commit OID-t a hook nem tudja bekötni -- a commit még nem létezik, amikor
# fut. A szerző, a committer és az üzenet viszont ismertek, és együtt zárják az
# átültetést.
#
# A remote URL és a SZÜLŐK szándékosan kimaradnak. A remote URL környezeti
# állapot (SSH/HTTPS/mirror mind más). A szülők azért nem, mert a hook a commit
# előtt fut: `--amend`-nél a HEAD nem az új commit szülője, a `git rebase` pedig
# nem futtatja újra a hookot, csak átviszi a régi blokkot egy új szülő alá --
# mindkettő mérve. Ebben a projektben a rebase minden PR előtt kötelező.
manifest_digest_v3() {
    local c="$1" tree author committer msg_sha
    tree=$(git rev-parse "$c^{tree}")
    author=$(git log -1 --format='%an <%ae>' "$c")
    committer=$(git log -1 --format='%cn <%ce>' "$c")
    # Az üzenet a signing blokk NÉLKÜL. A blokkot az UTOLSÓ olyan `---` sornál
    # vágjuk le, amit `[signing-metadata]` követ -- egy sima `sed '/^---$/,$d'`
    # levágta volna a felhasználó saját `---` elválasztóját is, és a commitja
    # ellenőrizhetetlenné vált volna anélkül, hogy bármi baja lenne.
    local body
    body=$(git log -1 --format=%B "$c" | awk '
        { line[NR] = $0; if ($0 == "---" && cut == 0) start = NR }
        $0 == "[signing-metadata]" && start == NR - 1 { cut = start }
        END { last = (cut ? cut - 1 : NR); for (i = 1; i <= last; i++) print line[i] }')
    # Ugyanaz a két normalizálás, mint a hookban: komment-strip és a záró
    # újsorok levágása a $( ) által.
    body=$(printf '%s\n' "$body" | git stripspace --strip-comments)
    msg_sha=$(printf '%s' "$body" | openssl dgst -sha256 -binary | openssl base64 -A)
    { printf 'cic-tree-manifest/v3\n'
      printf 'object-format: %s\n' "$(git rev-parse --show-object-format 2>/dev/null || echo sha1)"
      printf 'author: %s\n' "$author"
      printf 'committer: %s\n' "$committer"
      printf 'message-sha256: %s\n' "$msg_sha"
      printf 'tree: %s\n' "$tree"
      git ls-tree -r -t "$tree" | LC_ALL=C sort
    } | openssl dgst -sha256 -binary | openssl base64 -A
}

# Returns the umask that reproduces $2, or empty.
matching_umask() {
    local tree="$1" want="$2" m
    for m in "${UMASKS[@]}"; do
        [[ "$(tree_digest "$tree" "$m")" == "$want" ]] && { printf '%s' "$m"; return 0; }
    done
    return 1
}

# Recomputes the digest and verifies the signature against the embedded
# certificate. Prints nothing on success.
verify_commit() {
    local c="$1" msg rec sig tmp calc
    msg=$(git log -1 --format=%B "$c")

    rec=$(grep -oP '^digest = \K\S+' <<<"$msg" | head -1)
    sig=$(grep -oP '^signature = vault:v1:\K\S+' <<<"$msg" | head -1)
    if [[ -z "$rec" || -z "$sig" ]]; then
        echo "    nincs aláírás-metaadat"
        return 1
    fi

    local manifest mask
    manifest=$(grep -oP '^manifest = \K\S+' <<<"$msg" | head -1)
    case "$manifest" in
        cic-tree-manifest/v3)
            if [[ "$(manifest_digest_v3 "$c")" != "$rec" ]]; then
                echo "    a digest NEM erre a commitra illik (v3 manifest)"
                echo "      rögzített:   ${rec:0:32}…"
                echo "      újraszámolt: $(manifest_digest_v3 "$c" | cut -c1-32)…"
                echo "      A v3 a fán túl a szerzőt, a committert és az üzenetet"
                echo "      is köti — ezek bármelyike eltérhet."
                return 1
            fi
            ;;
        cic-tree-manifest/v2)
            if [[ "$(manifest_digest_v2 "$c^{tree}")" != "$rec" ]]; then
                echo "    a digest NEM a saját fájára illik (v2 manifest)"
                echo "      rögzített:   ${rec:0:32}…"
                echo "      újraszámolt: $(manifest_digest_v2 "$c^{tree}" | cut -c1-32)…"
                return 1
            fi
            ;;
        "")
            if ! mask=$(matching_umask "$c^{tree}" "$rec"); then
                echo "    a digest NEM a saját fájára illik (egyik umask mellett sem)"
                echo "      rögzített:   ${rec:0:32}…"
                echo "      újraszámolt: $(tree_digest "$c^{tree}" 022 | cut -c1-32)… (umask 022)"
                return 1
            fi
            [[ "$mask" == "022" ]] || echo "    (v1 manifest, umask $mask — a hook azóta v2-t ír)"
            ;;
        *)  echo "    ismeretlen manifest-verzió: $manifest"; return 1 ;;
    esac

    tmp=$(mktemp -d) || return 1
    sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' <<<"$msg" > "$tmp/cert.pem"
    if ! openssl x509 -in "$tmp/cert.pem" -noout -pubkey > "$tmp/pub.pem" 2>/dev/null; then
        echo "    nincs értelmezhető tanúsítvány az üzenetben"
        rm -rf "$tmp"; return 1
    fi
    base64 -d <<<"$sig" > "$tmp/sig.der" 2>/dev/null
    base64 -d <<<"$rec" > "$tmp/dig.bin" 2>/dev/null
    if ! openssl pkeyutl -verify -pubin -inkey "$tmp/pub.pem" \
            -in "$tmp/dig.bin" -sigfile "$tmp/sig.der" >/dev/null 2>&1; then
        echo "    az ECDSA aláírás NEM érvényes a tanúsítványra"
        rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
    return 0
}

if [[ -n "$RANGE" ]]; then
    if ! mapfile -t COMMITS < <(git rev-list "$RANGE" 2>/dev/null) || [[ ${#COMMITS[@]} -eq 0 ]]; then
        # An empty or unresolvable range used to print GO, which is the worst
        # possible answer: a typo in the range would have passed the gate while
        # verifying nothing.
        echo "Tartomány: $RANGE — ÜRES vagy feloldhatatlan"
        echo "  Ez nem rendben van: egy elgépelt tartomány így GO-t adna anélkül,"
        echo "  hogy bármit ellenőrzött volna."
        fail=$((fail + 1))
        COMMITS=()
    else
        echo "Tartomány: $RANGE — ${#COMMITS[@]} commit"
    fi
    for c in ${COMMITS[@]+"${COMMITS[@]}"}; do
        short=$(git log -1 --format='%h %s' "$c" | cut -c1-58)
        parents=$(git log -1 --format=%P "$c")
        if [[ $(wc -w <<<"$parents") -gt 1 ]]; then
            t=$(git rev-parse "$c^{tree}")
            introduces=1
            for p in $parents; do
                [[ "$(git rev-parse "$p^{tree}")" == "$t" ]] && introduces=0
            done
            if [[ "$introduces" -eq 0 ]]; then
                echo "  OK    $short  (merge, nem hoz tartalmat)"
                ok=$((ok + 1))
            elif verify_commit "$c"; then
                echo "  OK    $short  (merge, aláírt)"
                ok=$((ok + 1))
            else
                echo "  FAIL  $short  (merge tartalmat hoz és nincs aláírva)"
                fail=$((fail + 1))
            fi
        elif verify_commit "$c"; then
            echo "  OK    $short"
            ok=$((ok + 1))
        else
            echo "  FAIL  $short"
            fail=$((fail + 1))
        fi
    done
fi

if [[ -n "$TAG" ]]; then
    echo
    echo "Tag: $TAG"
    if ! git rev-parse -q --verify "$TAG" >/dev/null; then
        echo "  FAIL  nincs ilyen tag"
        fail=$((fail + 1))
    else
        c=$(git rev-list -1 "$TAG")
        if [[ $(git log -1 --format=%P "$c" | wc -w) -gt 1 ]]; then
            # A release tag has to name a commit whose own signature covers the
            # released tree. A merge commit is unsigned by construction, so a tag
            # on one points at content nothing vouches for.
            echo "  FAIL  $(git log -1 --format='%h %s' "$c" | cut -c1-58)"
            echo "        merge commitra mutat — tedd az aláírt szülőre"
            fail=$((fail + 1))
        elif verify_commit "$c"; then
            echo "  OK    $(git log -1 --format='%h %s' "$c" | cut -c1-58)"
            ok=$((ok + 1))
        else
            echo "  FAIL  $(git log -1 --format='%h %s' "$c" | cut -c1-58)"
            fail=$((fail + 1))
        fi
    fi
fi

echo
if [[ "$fail" -eq 0 ]]; then
    echo "verify-signatures: GO ($ok rendben)"
else
    echo "verify-signatures: NO-GO ($fail hibás, $ok rendben)"
fi
exit $(( fail > 0 ))
