#!/bin/bash
# shellcheck shell=bash disable=SC2034
# Is the archive signed, and by our key? The one question --apply must
# answer before it changes anything, and the one it must never assume.
# Sourced by lib/transition.sh after lib/common.sh.


# ARCHIVE_REASON: set by archive_verify, in words, for the report and for
# the refusal message. Never a return value: the return code is.
ARCHIVE_REASON=""

# archive_fetch URL FILE: one GET over IPv6 (BRIEF section 10). Kept apart
# from archive_verify so the tests can stub curl and reach every branch.
archive_fetch() {
    curl -fsS --ipv6 --max-time "$KEEL_CURL_TIMEOUT" -o "$2" "$1"
}

# archive_verify URI SUITE KEYRING DIR: is there a Release for SUITE that
# this keyring verifies? Returns 0 verified, 1 no signature published,
# 2 a signature that does not verify, 3 no keyring, 4 no verifier.
# It reads the archive; it does not configure it and does not call apt.
archive_verify() {
    local uri="$1" suite="$2" keyring="$3" dir="$4" base
    base="$uri/dists/$suite"
    if [ ! -r "$keyring" ]; then
        ARCHIVE_REASON="the archive keyring $keyring is missing: install keel-archive-keyring"
        return 3
    fi
    if ! command -v gpgv > /dev/null 2>&1; then
        ARCHIVE_REASON="gpgv is not installed, so no signature on $base can be checked"
        return 4
    fi
    if archive_fetch "$base/InRelease" "$dir/InRelease"; then
        if gpgv --quiet --keyring "$keyring" "$dir/InRelease" > "$dir/gpgv.log" 2>&1; then
            ARCHIVE_REASON="InRelease at $base is signed by the archive key"
            return 0
        fi
        ARCHIVE_REASON="InRelease at $base is not signed by the archive key"
        return 2
    fi
    if archive_fetch "$base/Release" "$dir/Release" &&
        archive_fetch "$base/Release.gpg" "$dir/Release.gpg"; then
        if gpgv --quiet --keyring "$keyring" "$dir/Release.gpg" "$dir/Release" > "$dir/gpgv.log" 2>&1; then
            ARCHIVE_REASON="Release at $base is signed by the archive key"
            return 0
        fi
        ARCHIVE_REASON="Release.gpg at $base is not a signature of Release by the archive key"
        return 2
    fi
    ARCHIVE_REASON="there is no InRelease and no Release.gpg at $base: that archive is unsigned today"
    return 1
}

