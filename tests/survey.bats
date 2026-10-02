#!/usr/bin/env bats
# Phase 1, the default: keel inspect, the report of what it could not
# infer, and the plan. Nothing under /etc/apt may change.

load helpers

setup() {
    scratch_setup
    turnkey_list
    install_keyring
    stub_curl_absent
    cp "$ROOT/etc/apt/sources.list.d/turnkey.list" "$TMP/turnkey.original"
}
teardown() { scratch_teardown; }

survey() { run "$REPO/bin/keel-transition" --root "$ROOT" "$@"; }

@test "the survey writes the spec, the report, and changes nothing under /etc/apt" {
    stub_keel
    survey
    [ "$status" -eq 0 ]
    [ -f "$ROOT/etc/keel/instance.yaml" ]
    [ -f "$ROOT/var/lib/keel/transition/survey-report.txt" ]
    grep -q 'hostname: bench' "$ROOT/etc/keel/instance.yaml"
    [ "$(ls "$ROOT/etc/apt/sources.list.d")" = turnkey.list ]
    [ -z "$(ls "$ROOT/etc/apt/preferences.d")" ]
    cmp "$TMP/turnkey.original" "$ROOT/etc/apt/sources.list.d/turnkey.list"
}

@test "the survey prints what it could not infer, once, without the summary line twice" {
    stub_keel
    survey
    [[ "$output" == *"could not infer, or will not read:"* ]]
    [[ "$output" == *"app.email: not inferred"* ]]
    [[ "$output" == *"not extracted: values are never read"* ]]
    [ "$(grep -c '8 inferred' <<< "$output")" -eq 1 ]
}

@test "the survey says so when every field was inferred" {
    stub_keel_complete
    survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"every field was inferred"* ]]
}

@test "the survey prints the three changes --apply would make, as would lines" {
    stub_keel
    survey
    [[ "$output" == *"would create"*"/etc/apt/sources.list.d/keel.sources"* ]]
    [[ "$output" == *"would create"*"/etc/apt/preferences.d/keel"* ]]
    [[ "$output" == *"would rename"*"turnkey.list"* ]]
    [[ "$output" == *"undo anything --apply does with: keel-transition --rollback"* ]]
}

@test "the survey says --apply would refuse today, and why" {
    stub_keel
    survey
    [[ "$output" == *"--apply would refuse today, exit 4"* ]]
    [[ "$output" == *"unsigned today"* ]]
}

@test "the survey does not print the refusal when the archive verifies" {
    local fpr
    fpr="$(make_signing_key archivekey)"
    serve_signed trixie "$fpr" "$fpr"
    stub_curl_serving "$SERVE"
    stub_keel
    survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"verified"* ]]
    [[ "$output" != *"would refuse today"* ]]
}

@test "the survey does not rewrite a spec that is already there" {
    mkdir -p "$ROOT/etc/keel"
    printf 'instance:\n  hostname: handwritten\n' > "$ROOT/etc/keel/instance.yaml"
    cp "$ROOT/etc/keel/instance.yaml" "$TMP/spec.original"
    stub_keel
    survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"already present: inspect ran, the file was not rewritten"* ]]
    cmp "$TMP/spec.original" "$ROOT/etc/keel/instance.yaml"
}

@test "the survey exits 3 when keel inspect could not infer a required field" {
    stub_keel 13
    survey
    [ "$status" -eq 3 ]
}

@test "the survey exits 5 when keel inspect could not write" {
    stub_keel 5
    survey
    [ "$status" -eq 5 ]
}

@test "any other keel exit is reported and treated as an incomplete survey" {
    stub_keel 7
    survey
    [ "$status" -eq 3 ]
    [[ "$output" == *"keel inspect exited 7"* ]]
}

@test "the survey says so when the keel command is not installed" {
    survey
    [ "$status" -eq 8 ]
    [[ "$output" == *"the keel command is not installed"* ]]
    [ ! -e "$ROOT/etc/keel/instance.yaml" ]
}

@test "the survey exits 5 when the spec directory cannot be made" {
    stub_keel
    printf 'not a directory\n' > "$ROOT/etc/keel"
    survey
    [ "$status" -eq 5 ]
}

@test "--no-inspect surveys the apt state only" {
    stub_keel
    survey --no-inspect
    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-inspect: the spec was not touched"* ]]
    [ ! -e "$ROOT/etc/keel/instance.yaml" ]
}

@test "the survey says when there is no report to read" {
    stub keel 'exit 0'
    survey
    [ "$status" -eq 0 ]
    [[ "$output" == *"no report at"* ]]
}

@test "the survey names the key the keyring package installed" {
    stub_keel
    survey
    [[ "$output" == *"key AD0964BE3F09DED469A3B6B2148E951314703180"* ]]
}

@test "the survey says it would replace the deb822 TurnKey sources with Debian's" {
    stub_keel
    cat > "$ROOT/etc/apt/sources.list.d/sources.sources" << SRC
Types: deb
URIs: http://archive.turnkeylinux.org/debian
Suites: trixie
Components: main

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main non-free-firmware
SRC
    survey
    [[ "$output" == *"would rename"*"sources.sources"*"sources.sources.disabled-by-keel"* ]]
    [[ "$output" == *"would create"*"debian.sources"* ]]
    [[ "$output" != *"the pin at"* ]]
    [ -f "$ROOT/etc/apt/sources.list.d/sources.sources" ]
    [ ! -e "$ROOT/etc/apt/sources.list.d/debian.sources" ]
}

@test "the survey says nothing about deb822 sources when there are none" {
    stub_keel
    survey
    [[ "$output" != *"left enabled"* ]]
}
