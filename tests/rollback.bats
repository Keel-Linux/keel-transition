#!/usr/bin/env bats
# Phase 3: undo exactly what --apply did. The upstream list must come back
# byte for byte, and a second rollback must be a no-op.

load helpers

setup() {
    scratch_setup
    turnkey_list
    install_keyring
    stub_keel
    stub_curl_absent
    cp "$ROOT/etc/apt/sources.list.d/turnkey.list" "$TMP/turnkey.original"
    mkdir -p "$TMP/etc.original"
    SOURCES="$ROOT/etc/apt/sources.list.d/keel.sources"
    PREFS="$ROOT/etc/apt/preferences.d/keel"
    LIST="$ROOT/etc/apt/sources.list.d/turnkey.list"
    cp -a "$ROOT/etc/apt" "$TMP/apt.original"
}
teardown() { scratch_teardown; }

rollback() { run "$REPO/bin/keel-transition" --rollback --root "$ROOT" "$@"; }

@test "rollback restores /etc/apt byte for byte after an apply" {
    applied
    rollback
    [ "$status" -eq 0 ]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "rollback names each file it undid" {
    applied
    rollback
    [[ "$output" == *"remove"*"keel.sources"* ]]
    [[ "$output" == *"remove"*"preferences.d/keel"* ]]
    [[ "$output" == *"rename"*"turnkey.list"* ]]
    [[ "$output" == *"byte for byte"* ]]
}

@test "the restored upstream list is the original file, content and mode" {
    applied
    rollback
    cmp "$TMP/turnkey.original" "$LIST"
    [ "$(stat -c %a "$TMP/apt.original/sources.list.d/turnkey.list")" = "$(stat -c %a "$LIST")" ]
    [ ! -e "$LIST.disabled-by-keel" ]
}

@test "rollback twice is a no-op and still exits 0" {
    applied
    rollback
    [ "$status" -eq 0 ]
    rollback
    [ "$status" -eq 0 ]
    [[ "$output" == *"keep"*"not present"* ]]
    [[ "$output" == *"already enabled"* ]]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$status" -eq 0 ]
}

@test "rollback on a machine that was never applied to changes nothing" {
    rollback
    [ "$status" -eq 0 ]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$status" -eq 0 ]
}

@test "apply, rollback, apply, rollback leaves the same bytes every time" {
    applied
    cp "$SOURCES" "$TMP/sources.first"
    rollback
    [ "$status" -eq 0 ]
    applied
    cmp "$TMP/sources.first" "$SOURCES"
    rollback
    [ "$status" -eq 0 ]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$status" -eq 0 ]
}

@test "rollback leaves a keel.sources somebody else wrote, and exits 7" {
    applied
    printf 'hand written by the operator\n' > "$SOURCES"
    rollback
    [ "$status" -eq 7 ]
    [[ "$output" == *"refuse"* ]]
    [[ "$output" == *"not written by this tool"* ]]
    [ "$(cat "$SOURCES")" = "hand written by the operator" ]
}

@test "rollback refuses when both turnkey names exist, and exits 7" {
    applied
    turnkey_list
    rollback
    [ "$status" -eq 7 ]
    [[ "$output" == *"both names exist"* ]]
    [ -e "$LIST.disabled-by-keel" ]
}

@test "rollback says the instance spec is the operator's to remove" {
    applied
    rollback
    [[ "$output" == *"the spec the survey wrote is yours"* ]]
    [ -f "$ROOT/etc/keel/instance.yaml" ]
}

@test "rollback touches no package" {
    applied
    rollback
    [[ "$output" == *"no package was installed, upgraded or removed"* ]]
}
