#!/bin/bash
# shellcheck shell=bash disable=SC2154
# Shared setup for the bats suite (decision 0004). Every test runs against
# a scratch tree: a fake /etc under $ROOT reached through --root, PATH
# stubs for curl, keel and id, and throwaway OpenPGP keys generated inside
# the test, never the project key. Nothing here touches the live system,
# needs root or reaches the network.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# scratch_setup: a fresh tree and environment for one test.
scratch_setup() {
    TMP="$(mktemp -d)"
    export TMP
    export ROOT="$TMP/root"
    export STUBS="$TMP/stubs"
    export SERVE="$TMP/serve"
    export KEEL_TRANSITION_LIB="$REPO/lib"
    export GNUPGHOME="$TMP/gnupg"
    mkdir -p "$ROOT/etc/apt/sources.list.d" "$ROOT/etc/apt/preferences.d" "$STUBS" "$SERVE"
    mkdir -m 700 "$GNUPGHOME"
    export PATH="$STUBS:$PATH"
}

scratch_teardown() {
    gpgconf --kill gpg-agent 2> /dev/null || true
    rm -rf "$TMP"
}

# stub NAME BODY: an executable first in PATH.
stub() {
    printf '#!/bin/bash\n%s\n' "$2" > "$STUBS/$1"
    chmod +x "$STUBS/$1"
}

# turnkey_list: the upstream sources list a Core 19.0 appliance ships.
turnkey_list() {
    cat > "$ROOT/etc/apt/sources.list.d/turnkey.list" << LIST
deb https://archive.turnkeylinux.org/debian trixie main
deb https://archive.turnkeylinux.org/debian trixie-security main
LIST
}

# install_keyring: what the keel-archive-keyring package installs.
install_keyring() {
    mkdir -p "$ROOT/usr/share/keyrings" "$ROOT/usr/share/keel-archive-keyring"
    gpg --dearmor < "$REPO/keys/keel-archive-keyring.asc" \
        > "$ROOT/usr/share/keyrings/keel-archive-keyring.gpg" 2> /dev/null
    cp "$REPO/keys/FINGERPRINT" "$ROOT/usr/share/keel-archive-keyring/fingerprint"
}

# stub_curl_absent: every fetch fails the way --fail does on a 404.
stub_curl_absent() {
    stub curl 'exit 22'
}

# stub_curl_serving DIR: curl that copies DIR/<path of the URL> into -o,
# and fails with 22 when the file is not there. IPv6 only, like the tool.
stub_curl_serving() {
    stub curl "root='$1'
out=''; url=''; ipv6=0
while [ \$# -gt 0 ]; do
    case \"\$1\" in
        -o) out=\"\$2\"; shift 2 ;;
        --max-time) shift 2 ;;
        --ipv6) ipv6=1; shift ;;
        -*) shift ;;
        *) url=\"\$1\"; shift ;;
    esac
done
[ \"\$ipv6\" = 1 ] || exit 99
path=\"\${url#*://}\"; path=\"\${path#*/}\"
[ -f \"\$root/\$path\" ] || exit 22
cp \"\$root/\$path\" \"\$out\""
}

# stub_keel [EXIT]: a keel that writes a plausible spec and report and
# exits EXIT (default 0). The real keel is tested in its own repository.
stub_keel() {
    stub keel "out=''; rep=''
while [ \$# -gt 0 ]; do
    case \"\$1\" in
        --output) out=\"\$2\"; shift 2 ;;
        --report) rep=\"\$2\"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n \"\$out\" ] && printf 'instance:\n  hostname: bench\n  fqdn: bench.example.org\n' > \"\$out\"
[ -n \"\$rep\" ] && printf 'instance.hostname: bench (from /etc/hostname)\napp.email: not inferred: /etc/inithooks.conf not present\nsecrets.root_password: file: /etc/keel/secrets/root_password (not extracted: values are never read)\ninspect: 8 inferred, 1 not inferred (0 required), 1 secrets to provide; spec complete\n' > \"\$rep\"
exit ${1:-0}"
}

# stub_keel_complete: a keel whose report has no gap at all.
stub_keel_complete() {
    stub keel "out=''; rep=''
while [ \$# -gt 0 ]; do
    case \"\$1\" in
        --output) out=\"\$2\"; shift 2 ;;
        --report) rep=\"\$2\"; shift 2 ;;
        *) shift ;;
    esac
done
[ -n \"\$out\" ] && printf 'instance:\n  hostname: bench\n' > \"\$out\"
[ -n \"\$rep\" ] && printf 'instance.hostname: bench (from /etc/hostname)\ninspect: 9 inferred, 0 not inferred (0 required); spec complete\n'> \"\$rep\"
exit 0"
}

# make_signing_key NAME: a throwaway signing key; echoes its fingerprint.
make_signing_key() {
    gpg --batch --quiet --passphrase '' --pinentry-mode loopback \
        --quick-generate-key "$1 <$1@example.invalid>" ed25519 sign never 2> /dev/null
    gpg --batch --with-colons --list-keys "$1@example.invalid" |
        awk -F: '$1 == "fpr" { print $10; exit }'
}

# serve_signed SUITE SIGNER TRUSTED: a dists/SUITE tree under $SERVE with
# InRelease, Release and Release.gpg made by SIGNER, and a keyring at
# $TMP/keyring.gpg holding TRUSTED. Signer and trusted differ in the test
# that proves a foreign signature is refused.
serve_signed() {
    local suite="$1" signer="$2" trusted="$3" dir="$SERVE/dists/$1"
    mkdir -p "$dir"
    cat > "$TMP/Release.plain" << RELEASE
Origin: Keel Linux
Label: Keel Linux
Suite: stable
Codename: $suite
Components: main
Architectures: amd64
RELEASE
    gpg --batch --quiet --yes --local-user "$signer" --clearsign \
        -o "$dir/InRelease" "$TMP/Release.plain" 2> /dev/null
    cp "$TMP/Release.plain" "$dir/Release"
    gpg --batch --quiet --yes --local-user "$signer" --detach-sign --armor \
        -o "$dir/Release.gpg" "$dir/Release" 2> /dev/null
    gpg --batch --quiet --yes --export "$trusted" > "$TMP/keyring.gpg" 2> /dev/null
    install_keyring
    cp "$TMP/keyring.gpg" "$ROOT/usr/share/keyrings/keel-archive-keyring.gpg"
}

# applied: --apply already ran once against $ROOT, unsigned archive.
applied() {
    run "$REPO/bin/keel-transition" --apply --force-unsigned --root "$ROOT" \
        --archive-uri http://[2001:db8::1]
    [ "$status" -eq 0 ]
}
