#!/usr/bin/env bats
# lib/archive.sh: the question --apply must answer before it changes
# anything. Every return of archive_verify has a test, with real OpenPGP
# signatures made by throwaway keys generated inside each test.

load helpers

bats_require_minimum_version 1.5.0

setup() {
    scratch_setup
    . "$REPO/lib/transition.sh"
    KEEL_ROOT="$ROOT"
    KEYRING="$ROOT/usr/share/keyrings/keel-archive-keyring.gpg"
}
teardown() { scratch_teardown; }

@test "archive_fetch asks for IPv6 and copies the body to the file" {
    mkdir -p "$SERVE/dists/trixie"
    printf 'body\n' > "$SERVE/dists/trixie/InRelease"
    stub_curl_serving "$SERVE"
    run archive_fetch "https://archive.keellinux.org/dists/trixie/InRelease" "$TMP/out"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/out")" = body ]
}

@test "archive_fetch fails like --fail when the file is not published" {
    stub_curl_serving "$SERVE"
    run archive_fetch "https://archive.keellinux.org/dists/trixie/InRelease" "$TMP/out"
    [ "$status" -eq 22 ]
}

@test "archive_verify returns 3 when the keyring package is not installed" {
    stub_curl_absent
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 3 ]
    [[ "$output" == "" ]]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP" || true
    [[ "$ARCHIVE_REASON" == *"keyring"*"is missing"* ]]
}

@test "archive_verify returns 4 when there is no gpgv to verify with" {
    install_keyring
    PATH="$TMP/empty-bin" run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 4 ]
}

@test "archive_verify returns 1 when the archive publishes no signature at all" {
    install_keyring
    stub_curl_absent
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 1 ]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP" || true
    [[ "$ARCHIVE_REASON" == *"no InRelease and no Release.gpg"* ]]
    [[ "$ARCHIVE_REASON" == *"unsigned today"* ]]
}

@test "archive_verify returns 0 for an InRelease signed by the archive key" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    stub_curl_serving "$SERVE"
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 0 ]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [[ "$ARCHIVE_REASON" == *"InRelease"*"is signed by the archive key"* ]]
}

@test "archive_verify returns 2 for an InRelease signed by somebody else" {
    local signer other
    signer="$(make_signing_key intruder)"
    other="$(make_signing_key archivekey)"
    serve_signed trixie "$signer" "$other"
    stub_curl_serving "$SERVE"
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 2 ]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP" || true
    [[ "$ARCHIVE_REASON" == *"not signed by the archive key"* ]]
}

@test "archive_verify falls back to Release plus Release.gpg and accepts a good one" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    rm "$SERVE/dists/trixie/InRelease"
    stub_curl_serving "$SERVE"
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 0 ]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [[ "$ARCHIVE_REASON" == *"Release at"*"is signed by the archive key"* ]]
}

@test "archive_verify returns 2 when Release.gpg is not a signature of Release" {
    local signer other
    signer="$(make_signing_key intruder)"
    other="$(make_signing_key archivekey)"
    serve_signed trixie "$signer" "$other"
    rm "$SERVE/dists/trixie/InRelease"
    stub_curl_serving "$SERVE"
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 2 ]
    archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP" || true
    [[ "$ARCHIVE_REASON" == *"not a signature of Release"* ]]
}

@test "archive_verify returns 1 when Release is served without its signature" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    rm "$SERVE/dists/trixie/InRelease" "$SERVE/dists/trixie/Release.gpg"
    stub_curl_serving "$SERVE"
    run archive_verify https://archive.keellinux.org trixie "$KEYRING" "$TMP"
    [ "$status" -eq 1 ]
}

@test "archive_state reports the verdict and the key the keyring package recorded" {
    install_keyring
    stub_curl_absent
    KEEL_ARCHIVE_URI=https://archive.keellinux.org
    run archive_state
    [ "$status" -eq 1 ]
    [[ "$output" == *"unverified"* ]]
    [[ "$output" == *"AD0964BE3F09DED469A3B6B2148E951314703180"* ]]
}

@test "archive_state says the keyring package is missing when it is" {
    stub_curl_absent
    run archive_state
    [ "$status" -eq 3 ]
    [[ "$output" == *"keel-archive-keyring is not installed"* ]]
}

@test "archive_state reports a verified archive" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    stub_curl_serving "$SERVE"
    run archive_state
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified"* ]]
}

@test "warn_unsigned names the risk in words before anything is written" {
    ARCHIVE_REASON="that archive is unsigned today"
    run --separate-stderr warn_unsigned
    [ "$output" = "" ]
    [[ "$stderr" == *"Trusted: yes"* ]]
    [[ "$stderr" == *"without verifying any"* ]]
    [[ "$stderr" == *"runs as root"* ]]
    [[ "$stderr" == *"test bench, never on a live one"* ]]
}
