#!/usr/bin/env bats
# bin/keel-transition and transition_main: the arguments, the help, and
# the two refusals that happen before any phase starts.

load helpers

setup() { scratch_setup; }
teardown() { scratch_teardown; }

@test "the executable prints its version" {
    run "$REPO/bin/keel-transition" --version
    [ "$status" -eq 0 ]
    [ "$output" = "keel-transition 0.2.0" ]
}

@test "the help says the three phases, the refusal, the pin and the one package removed" {
    run "$REPO/bin/keel-transition" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"survey"* ]]
    [[ "$output" == *"--apply"* ]]
    [[ "$output" == *"--rollback"* ]]
    [[ "$output" == *"installs and upgrades nothing"* ]]
    [[ "$output" == *"The one"*"package it removes is turnkey-keys"* ]]
    [[ "$output" == *"The pin is 990, below 1000"* ]]
    [[ "$output" == *"refuses, with exit 4"* ]]
}

@test "-h is the same as --help" {
    run "$REPO/bin/keel-transition" -h
    [ "$status" -eq 0 ]
    [[ "$output" == usage:* ]]
}

@test "an unknown argument is a usage error and points at the help" {
    run "$REPO/bin/keel-transition" --bogus
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown argument: --bogus"* ]]
    [[ "$output" == *"--help"* ]]
}

@test "an option without its value is a usage error" {
    run "$REPO/bin/keel-transition" --root
    [ "$status" -eq 1 ]
    [[ "$output" == *"--root needs a value"* ]]
}

@test "--force-unsigned without --apply is a usage error" {
    run "$REPO/bin/keel-transition" --force-unsigned --root "$ROOT"
    [ "$status" -eq 1 ]
    [[ "$output" == *"means nothing without --apply"* ]]
}

@test "every option that takes a value reaches its variable" {
    stub_curl_absent
    install_keyring
    run "$REPO/bin/keel-transition" --no-inspect \
        --root "$ROOT" --archive-uri http://[2001:db8::2] --suite forky \
        --components "main contrib" --spec /etc/keel/other.yaml \
        --report /var/tmp/other.txt
    [ "$status" -eq 0 ]
    [[ "$output" == *"http://[2001:db8::2] forky main contrib"* ]]
    [[ "$output" == *"/dists/forky"* ]]
    [[ "$output" == *"$ROOT/etc/keel/other.yaml"* ]]
}

@test "--apply on the live system as a normal user refuses before touching anything" {
    stub id 'echo 1000'
    run "$REPO/bin/keel-transition" --apply --root ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"run it as root"* ]]
}

@test "--rollback on the live system as a normal user refuses before touching anything" {
    stub id 'echo 1000'
    run "$REPO/bin/keel-transition" --rollback --root ""
    [ "$status" -eq 2 ]
    [[ "$output" == *"run it as root"* ]]
}

@test "the survey needs no root" {
    stub id 'echo 1000'
    stub_curl_absent
    run "$REPO/bin/keel-transition" --no-inspect --root ""
    [ "$status" -eq 0 ]
}
