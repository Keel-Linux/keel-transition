#!/bin/bash
# shellcheck shell=bash
# What a TurnKey 19.0 appliance carries besides turnkey.list, and how
# --apply replaces it: the deb822 files TurnKey shares with Debian, its
# o=turnkeylinux pin at 999 in /etc/apt/preferences, and turnkey-keys.
# Every file is renamed, never deleted, and turnkey-keys is purged only
# after its files are kept, so --rollback can put each one back.
# Sourced by lib/transition.sh after lib/common.sh.

# turnkey_deb822_path NAME: one of KEEL_TURNKEY_DEB822, rooted
turnkey_deb822_path() {
    rooted "$(dirname "$KEEL_TURNKEY_LIST")/$1"
}

# turnkey_deb822_any: true when a known TurnKey deb822 file is there, live
# or already set aside by an earlier --apply
turnkey_deb822_any() {
    local name path
    for name in $KEEL_TURNKEY_DEB822; do
        path="$(turnkey_deb822_path "$name")"
        if [ -e "$path" ] || [ -e "$path$KEEL_DISABLED_SUFFIX" ]; then
            return 0
        fi
    done
    return 1
}

# turnkey_sources_unknown: files with a TurnKey stanza that this tool does
# not know, and so cannot replace without losing what else they say
turnkey_sources_unknown() {
    local file known name
    while read -r file; do
        [ -n "$file" ] || continue
        known=no
        for name in $KEEL_TURNKEY_DEB822; do
            [ "$file" = "$(turnkey_deb822_path "$name")" ] && known=yes
        done
        [ "$known" = yes ] || printf '%s\n' "$file"
    done <<< "$(turnkey_sources)"
}

# debian_field HOST FIELD: FIELD of the stanza naming HOST in TurnKey's
# shared files, live or set aside; the first one found
debian_field() {
    local name path file prog
    # one stanza a record; in the one naming HOST, print FIELD's value.
    # The $ are awk's, not the shell's.
    # shellcheck disable=SC2016
    prog='BEGIN { RS = "" } $0 ~ "URIs:[ \t]*[a-z]+://" host "/" { n = split($0, l, "\n"); for (i = 1; i <= n; i++) if (l[i] ~ "^" field ":") { sub("^" field ":[ \t]*", "", l[i]); print l[i]; exit } }'
    for name in $KEEL_TURNKEY_DEB822; do
        path="$(turnkey_deb822_path "$name")"
        for file in "$path" "$path$KEEL_DISABLED_SUFFIX"; do
            [ -f "$file" ] || continue
            awk -v host="$1" -v field="$2" "$prog" "$file" | head -n 1 | grep . && return 0
        done
    done
    return 1
}

# debian_render KIND: the deb822 file for KIND, debian or security, with
# the components and the release the appliance's own Debian stanza had
debian_render() {
    local codename components uri suites path
    codename="$(debian_field deb.debian.org Suites | awk '{ print $1 }')" || true
    codename="${codename:-trixie}"
    if [ "$1" = security ]; then
        uri=http://security.debian.org/debian-security
        suites="$codename-security"
        components="$(debian_field security.debian.org Components)" || true
        path="$KEEL_SECURITY_SOURCES"
    else
        uri=http://deb.debian.org/debian
        suites="$codename $codename-updates"
        components="$(debian_field deb.debian.org Components)" || true
        path="$KEEL_DEBIAN_SOURCES"
    fi
    printf '# Debian. %s as %s, in place of TurnKey'"'"'s\n' "$KEEL_MARKER" "$path"
    printf '# shared files; remove it again with: keel-transition --rollback\n'
    printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\n' \
        "$uri" "$suites" "${components:-main non-free-firmware}"
    printf 'Signed-By: %s\n' "$KEEL_DEBIAN_KEYRING"
}

# turnkey_pin_only FILE: true when every stanza of FILE pins o=turnkeylinux,
# so setting the file aside loses nothing else
turnkey_pin_only() {
    # one stanza a record, comments dropped; every stanza the TurnKey pin.
    # The $ are awk's, not the shell's.
    # shellcheck disable=SC2016
    local prog='BEGIN { RS = ""; all = 1; n = 0 } { gsub(/(^|\n)#[^\n]*/, ""); if ($0 ~ /^[ \t\n]*$/) next; n++; if ($0 !~ /Pin:[ \t]*release[ \t]+o=turnkeylinux/) all = 0 } END { exit !(all && n > 0) }'
    awk "$prog" "$1"
}

# dpkg_args: --root for a scratch tree, nothing for the live system
dpkg_args() {
    [ -z "$KEEL_ROOT" ] || printf -- '--root=%s\n' "$KEEL_ROOT"
}

# turnkey_keys_state: installed, config-files, or empty when dpkg has no
# record of turnkey-keys
turnkey_keys_state() {
    local args
    mapfile -t args < <(dpkg_args)
    # ${...} is dpkg-query's format, not the shell's
    # shellcheck disable=SC2016
    dpkg-query "${args[@]}" -W -f='${db:Status-Status}' turnkey-keys 2> /dev/null |
        awk '{ print $1 }' || true
}

# turnkey_keys_saved: where the files turnkey-keys owned are kept
turnkey_keys_saved() {
    printf '%s/turnkey-keys.tar\n' "$(rooted "$KEEL_STATE_DIR")"
}

# turnkey_keys_purge: keep the regular files turnkey-keys owns, then purge
# it through dpkg, so its files go with its record
turnkey_keys_purge() {
    local args list saved file owned
    mapfile -t args < <(dpkg_args)
    saved="$(turnkey_keys_saved)"
    mkdir -p "$(dirname "$saved")" || return 1
    list="$(mktemp)" || return 1
    owned="$(dpkg-query "${args[@]}" -L turnkey-keys 2> /dev/null || true)"
    while read -r file; do
        [ -n "$file" ] && [ -f "$(rooted "$file")" ] && printf '%s\n' "${file#/}" >> "$list"
    done <<< "$owned"
    if [ -s "$list" ]; then
        tar -C "${KEEL_ROOT:-/}" -cf "$saved" -T "$list" || { rm -f "$list"; return 1; }
    fi
    rm -f "$list"
    dpkg "${args[@]}" -P turnkey-keys
}

# turnkey_keys_restore: the kept files back where they were
turnkey_keys_restore() {
    local saved
    saved="$(turnkey_keys_saved)"
    tar -C "${KEEL_ROOT:-/}" -xf "$saved" && rm -f "$saved"
}
