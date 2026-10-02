#!/usr/bin/env bats
# Phase 2: the refusal, what --force-unsigned costs, what gets written,
# and that running it twice leaves the same bytes.

load helpers

setup() {
    scratch_setup
    turnkey_list
    install_keyring
    stub_keel
    cp "$ROOT/etc/apt/sources.list.d/turnkey.list" "$TMP/turnkey.original"
    SOURCES="$ROOT/etc/apt/sources.list.d/keel.sources"
    PREFS="$ROOT/etc/apt/preferences.d/keel"
    LIST="$ROOT/etc/apt/sources.list.d/turnkey.list"
}
teardown() { scratch_teardown; }

apply() { run "$REPO/bin/keel-transition" --apply --root "$ROOT" "$@"; }

@test "--apply refuses an archive with no verifiable signed Release, and changes nothing" {
    stub_curl_absent
    apply
    [ "$status" -eq 4 ]
    [[ "$output" == *"refusing --apply"* ]]
    [[ "$output" == *"no InRelease and no Release.gpg"* ]]
    [[ "$output" == *"install code as root here"* ]]
    [[ "$output" == *"nothing was changed"* ]]
    [[ "$output" == *"--force-unsigned"* ]]
    [ ! -e "$SOURCES" ]
    [ ! -e "$PREFS" ]
    cmp "$TMP/turnkey.original" "$LIST"
    [ ! -e "$ROOT/etc/keel/instance.yaml" ]
}

@test "--apply refuses an archive whose Release is signed by another key" {
    local signer other
    signer="$(make_signing_key intruder)"
    other="$(make_signing_key archivekey)"
    serve_signed trixie "$signer" "$other"
    stub_curl_serving "$SERVE"
    apply
    [ "$status" -eq 4 ]
    [[ "$output" == *"not signed by the archive key"* ]]
    [ ! -e "$SOURCES" ]
}

@test "--apply refuses with exit 6 when the keyring package is not installed" {
    rm -r "$ROOT/usr/share/keyrings"
    stub_curl_absent
    apply
    [ "$status" -eq 6 ]
    [[ "$output" == *"keel-archive-keyring"* ]]
    [ ! -e "$SOURCES" ]
}

@test "--apply on a verified archive writes a source with the signature check on" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    stub_curl_serving "$SERVE"
    apply
    [ "$status" -eq 0 ]
    grep -q 'Signed-By: /usr/share/keyrings/keel-archive-keyring.gpg' "$SOURCES"
    ! grep -q 'Trusted' "$SOURCES"
}

@test "--force-unsigned on a verified archive is ignored and says so" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    stub_curl_serving "$SERVE"
    apply --force-unsigned
    [ "$status" -eq 0 ]
    [[ "$output" == *"--force-unsigned ignored"* ]]
    ! grep -q 'Trusted' "$SOURCES"
}

@test "--force-unsigned warns, then writes the three changes" {
    stub_curl_absent
    apply --force-unsigned
    [ "$status" -eq 0 ]
    [[ "$output" == *"WARNING: --force-unsigned"* ]]
    [[ "$output" == *"Trusted: yes"* ]]
    [[ "$output" == *"never on a live one"* ]]
    grep -q 'URIs: https://archive.keellinux.org' "$SOURCES"
    grep -q 'Suites: trixie' "$SOURCES"
    grep -q 'Components: main' "$SOURCES"
    grep -q 'Trusted: yes' "$SOURCES"
    grep -q 'Pin: release o=Keel Linux' "$PREFS"
    grep -q 'Pin-Priority: 990' "$PREFS"
    [ ! -e "$LIST" ]
    cmp "$TMP/turnkey.original" "$LIST.disabled-by-keel"
}

@test "--apply writes the instance spec as the survey does" {
    stub_curl_absent
    apply --force-unsigned
    [ -f "$ROOT/etc/keel/instance.yaml" ]
    [[ "$output" == *"written by keel inspect"* ]]
}

@test "--apply says it installed, upgraded and removed no package" {
    stub_curl_absent
    apply --force-unsigned
    [[ "$output" == *"no package was installed, upgraded or removed"* ]]
    [[ "$output" == *"Run apt-get update yourself"* ]]
}

@test "--apply twice leaves byte identical files and the same exit code" {
    stub_curl_absent
    apply --force-unsigned
    [ "$status" -eq 0 ]
    cp "$SOURCES" "$TMP/sources.first"
    cp "$PREFS" "$TMP/prefs.first"
    cp "$LIST.disabled-by-keel" "$TMP/list.first"
    apply --force-unsigned
    [ "$status" -eq 0 ]
    [[ "$output" == *"update"* ]]
    [[ "$output" == *"already disabled by an earlier --apply"* ]]
    cmp "$TMP/sources.first" "$SOURCES"
    cmp "$TMP/prefs.first" "$PREFS"
    cmp "$TMP/list.first" "$LIST.disabled-by-keel"
}

@test "--apply leaves a keel.sources somebody else wrote and exits 5" {
    stub_curl_absent
    printf 'hand written by the operator\n' > "$SOURCES"
    apply --force-unsigned
    [ "$status" -eq 5 ]
    [[ "$output" == *"refuse"* ]]
    [ "$(cat "$SOURCES")" = "hand written by the operator" ]
}

@test "--apply carries on when keel is not installed, and says so" {
    rm "$STUBS/keel"
    stub_curl_absent
    apply --force-unsigned
    [ "$status" -eq 0 ]
    [[ "$output" == *"the keel command is not installed"* ]]
    grep -q 'Types: deb' "$SOURCES"
}

@test "--apply --no-inspect changes apt and leaves the spec alone" {
    stub_curl_absent
    apply --force-unsigned --no-inspect
    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-inspect: the spec was not touched"* ]]
    [ ! -e "$ROOT/etc/keel/instance.yaml" ]
    grep -q 'Types: deb' "$SOURCES"
}

@test "--apply against another archive and suite writes what it was given" {
    stub_curl_absent
    apply --force-unsigned --archive-uri "http://[2804:710:d0:5::13]:8081" --suite trixie-staging
    [ "$status" -eq 0 ]
    grep -q 'URIs: http://\[2804:710:d0:5::13\]:8081' "$SOURCES"
    grep -q 'Suites: trixie-staging' "$SOURCES"
}
