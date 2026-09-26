#!/bin/bash
# shellcheck shell=bash disable=SC2034
# Paths, exit codes, logging, the state of each file the tool owns, and the
# rendering of the two files it writes. Sourced by lib/transition.sh first.
#
# Paths on an appliance, every one overridable from the environment so the
# tests run against a scratch tree:
#   KEEL_ROOT        prefix for every path below; empty means the live system
#   KEEL_SOURCES     /etc/apt/sources.list.d/keel.sources, the deb822 source
#   KEEL_PREFS       /etc/apt/preferences.d/keel, the origin pin
#   KEEL_TURNKEY_LIST  /etc/apt/sources.list.d/turnkey.list, renamed, never deleted
#   KEEL_SPEC        /etc/keel/instance.yaml, what keel inspect writes
#   KEEL_REPORT      the field by field report of that inspect
#   KEEL_KEYRING_GPG the dearmored key keel-archive-keyring installs

KEEL_ROOT="${KEEL_ROOT:-}"
KEEL_ARCHIVE_URI="${KEEL_ARCHIVE_URI:-https://archive.keellinux.org}"
KEEL_ARCHIVE_SUITE="${KEEL_ARCHIVE_SUITE:-trixie}"
KEEL_ARCHIVE_COMPONENTS="${KEEL_ARCHIVE_COMPONENTS:-main}"
KEEL_KEYRING_GPG="${KEEL_KEYRING_GPG:-/usr/share/keyrings/keel-archive-keyring.gpg}"
KEEL_FINGERPRINT_FILE="${KEEL_FINGERPRINT_FILE:-/usr/share/keel-archive-keyring/fingerprint}"
KEEL_PIN_ORIGIN="${KEEL_PIN_ORIGIN:-Keel Linux}"
KEEL_PIN_PRIORITY="${KEEL_PIN_PRIORITY:-1001}"
KEEL_SPEC="${KEEL_SPEC:-/etc/keel/instance.yaml}"
KEEL_REPORT="${KEEL_REPORT:-/var/lib/keel/transition/survey-report.txt}"
KEEL_SOURCES="${KEEL_SOURCES:-/etc/apt/sources.list.d/keel.sources}"
KEEL_PREFS="${KEEL_PREFS:-/etc/apt/preferences.d/keel}"
KEEL_TURNKEY_LIST="${KEEL_TURNKEY_LIST:-/etc/apt/sources.list.d/turnkey.list}"
KEEL_DISABLED_SUFFIX="${KEEL_DISABLED_SUFFIX:-.disabled-by-keel}"

# The line every file this tool writes carries, and the only licence it has
# to remove one again: a file without it was written by somebody else.
KEEL_MARKER="Installed by keel-transition"

EXIT_OK=0
EXIT_USAGE=1
EXIT_NEEDS_ROOT=2
EXIT_SURVEY_INCOMPLETE=3
EXIT_ARCHIVE_UNSIGNED=4
EXIT_WRITE_FAILED=5
EXIT_KEYRING_MISSING=6
EXIT_ROLLBACK_INCOMPLETE=7
EXIT_KEEL_MISSING=8

PROG="keel-transition"

# log MESSAGE: one line on stderr, prefixed with the program name. Nothing
# in this library exits: a phase returns its code and transition_main is
# the only place that decides what the process does with it.
log() {
    printf '%s: %s\n' "$PROG" "$*" >&2
}

# rooted PATH: PATH inside KEEL_ROOT, which is empty for the live system.
rooted() {
    printf '%s%s\n' "$KEEL_ROOT" "$1"
}

# pin_render ORIGIN PRIORITY: the apt preferences file, byte for byte what
# the apt tooling's bin/pin-file renders (repos/apt lib/pin.sh). The pin is
# on the Origin of the signed Release, not on the host name, so it follows
# the packages to any mirror; 1001 is above 1000 so a +keel1 rebuild is kept
# even when upstream publishes a higher version (BRIEF section 7).
pin_render() {
    local origin="$1" priority="$2"
    cat << PIN
# Keel Linux: prefer the project's packages over every other archive.
# $KEEL_MARKER as $KEEL_PREFS.
Package: *
Pin: release o=$origin
Pin-Priority: $priority
PIN
}

# sources_render URI SUITE COMPONENTS KEYRING TRUSTED: the deb822 stanza.
# TRUSTED is "yes" only under --force-unsigned, and then the stanza says so
# in a comment as well as in the field, because the field is what makes apt
# accept packages nobody signed.
sources_render() {
    local uri="$1" suite="$2" components="$3" keyring="$4" trusted="$5"
    printf '# Keel Linux archive. %s as %s;\n' "$KEEL_MARKER" "$KEEL_SOURCES"
    printf '# remove it again with: keel-transition --rollback\n'
    if [ "$trusted" = yes ]; then
        printf '# WARNING: Trusted: yes. Signature checking is off for this\n'
        printf '# archive: apt will install packages whose origin nothing proves.\n'
    fi
    printf 'Types: deb\n'
    printf 'URIs: %s\n' "$uri"
    printf 'Suites: %s\n' "$suite"
    printf 'Components: %s\n' "$components"
    printf 'Signed-By: %s\n' "$keyring"
    if [ "$trusted" = yes ]; then
        printf 'Trusted: yes\n'
    fi
}

# file_is_ours FILE: true when the file carries the marker, so removing or
# rewriting it destroys nothing the operator wrote.
file_is_ours() {
    [ -f "$1" ] && grep -qF "$KEEL_MARKER" "$1"
}

# state_file FILE: absent, ours or foreign.
state_file() {
    if [ ! -e "$1" ]; then
        printf 'absent\n'
    elif file_is_ours "$1"; then
        printf 'ours\n'
    else
        printf 'foreign\n'
    fi
}

# state_turnkey: absent, enabled, disabled or both, for the upstream list
# and the name this tool renames it to.
state_turnkey() {
    local live disabled
    live="$(rooted "$KEEL_TURNKEY_LIST")"
    disabled="$live$KEEL_DISABLED_SUFFIX"
    if [ -e "$live" ] && [ -e "$disabled" ]; then
        printf 'both\n'
    elif [ -e "$live" ]; then
        printf 'enabled\n'
    elif [ -e "$disabled" ]; then
        printf 'disabled\n'
    else
        printf 'absent\n'
    fi
}

# keyring_fingerprint: the fingerprint the keyring package recorded, or the
# empty string when the package is not installed.
keyring_fingerprint() {
    local file
    file="$(rooted "$KEEL_FINGERPRINT_FILE")"
    [ -r "$file" ] || return 1
    tr -d '[:space:]' < "$file"
}

KEEL_TRANSITION_VERSION="0.1.0"
KEEL_CURL_TIMEOUT="${KEEL_CURL_TIMEOUT:-30}"
