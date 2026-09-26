#!/usr/bin/env bats
# lib/plan.sh: what each phase would do, as records, how they are printed
# and how they are carried out. Every state of every file has a record.

load helpers

bats_require_minimum_version 1.5.0

setup() {
    scratch_setup
    . "$REPO/lib/transition.sh"
    KEEL_ROOT="$ROOT"
    SOURCES="$ROOT/etc/apt/sources.list.d/keel.sources"
    PREFS="$ROOT/etc/apt/preferences.d/keel"
    LIST="$ROOT/etc/apt/sources.list.d/turnkey.list"
}
teardown() { scratch_teardown; }

ours() { printf '# %s as x\n' "$KEEL_MARKER" > "$1"; }

@test "plan_apply on a stock appliance creates both files and renames the upstream list" {
    turnkey_list
    run plan_apply no
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == create-sources* ]]
    [[ "${lines[0]}" == *"Signed-By"* ]]
    [[ "${lines[1]}" == create-pin* ]]
    [[ "${lines[1]}" == *"release o=Keel Linux at 1001"* ]]
    [[ "${lines[2]}" == disable-turnkey* ]]
    [[ "${lines[2]}" == *"turnkey.list.disabled-by-keel"* ]]
}

@test "plan_apply with trusted says the source will carry Trusted: yes" {
    run plan_apply yes
    [[ "${lines[0]}" == *"Trusted: yes (unsigned)"* ]]
}

@test "plan_apply updates files it wrote itself and keeps an already disabled list" {
    ours "$SOURCES"
    ours "$PREFS"
    : > "$LIST.disabled-by-keel"
    run plan_apply no
    [[ "${lines[0]}" == update-sources* ]]
    [[ "${lines[1]}" == update-pin* ]]
    [[ "${lines[2]}" == keep-turnkey* ]]
    [[ "${lines[2]}" == *"already disabled"* ]]
}

@test "plan_apply refuses to overwrite files somebody else wrote" {
    printf 'hand written\n' > "$SOURCES"
    printf 'hand written\n' > "$PREFS"
    run plan_apply no
    [[ "${lines[0]}" == conflict-sources* ]]
    [[ "${lines[1]}" == conflict-pin* ]]
}

@test "plan_apply reports both turnkey names as a conflict and no upstream list as nothing to do" {
    turnkey_list
    : > "$LIST.disabled-by-keel"
    run plan_apply no
    [[ "${lines[2]}" == conflict-turnkey* ]]
    rm "$LIST" "$LIST.disabled-by-keel"
    run plan_apply no
    [[ "${lines[2]}" == keep-turnkey* ]]
    [[ "${lines[2]}" == *"no upstream list"* ]]
}

@test "plan_rollback removes what we wrote and restores the upstream list" {
    ours "$SOURCES"
    ours "$PREFS"
    : > "$LIST.disabled-by-keel"
    run plan_rollback
    [[ "${lines[0]}" == remove-sources* ]]
    [[ "${lines[1]}" == remove-pin* ]]
    [[ "${lines[2]}" == restore-turnkey* ]]
    [[ "${lines[2]}" == *"byte for byte"* ]]
}

@test "plan_rollback on a machine that was never applied to has nothing to undo" {
    run plan_rollback
    [[ "${lines[0]}" == keep-sources* ]]
    [[ "${lines[1]}" == keep-pin* ]]
    [[ "${lines[2]}" == keep-turnkey* ]]
    turnkey_list
    run plan_rollback
    [[ "${lines[2]}" == keep-turnkey* ]]
    [[ "${lines[2]}" == *"already enabled"* ]]
}

@test "plan_rollback leaves files somebody else wrote and reports both turnkey names" {
    printf 'hand written\n' > "$SOURCES"
    printf 'hand written\n' > "$PREFS"
    turnkey_list
    : > "$LIST.disabled-by-keel"
    run plan_rollback
    [[ "${lines[0]}" == conflict-sources* ]]
    [[ "${lines[1]}" == conflict-pin* ]]
    [[ "${lines[2]}" == conflict-turnkey* ]]
}

@test "plan_verb turns a record into the word it is reported with" {
    [ "$(plan_verb create-sources done)" = create ]
    [ "$(plan_verb create-sources would)" = "would create" ]
    [ "$(plan_verb update-pin would)" = "would update" ]
    [ "$(plan_verb remove-pin would)" = "would remove" ]
    [ "$(plan_verb disable-turnkey would)" = "would rename" ]
    [ "$(plan_verb restore-turnkey done)" = rename ]
    [ "$(plan_verb keep-turnkey would)" = keep ]
    [ "$(plan_verb conflict-pin would)" = refuse ]
}

@test "plan_render prints one aligned line per record" {
    run plan_render would <<< "$(printf 'create-pin\t/etc/apt/preferences.d/keel\ta note')"
    [ "$status" -eq 0 ]
    [[ "$output" == *"would create"* ]]
    [[ "$output" == *"/etc/apt/preferences.d/keel"* ]]
    [[ "$output" == *"a note"* ]]
}

@test "plan_execute writes both files and renames the upstream list" {
    turnkey_list
    cp "$LIST" "$TMP/original"
    plan_apply no | plan_execute no 5
    grep -q 'Types: deb' "$SOURCES"
    grep -q 'Pin-Priority: 1001' "$PREFS"
    [ ! -e "$LIST" ]
    cmp "$TMP/original" "$LIST.disabled-by-keel"
}

@test "plan_execute returns the conflict code it was given, once per refusal" {
    printf 'hand written\n' > "$SOURCES"
    run plan_execute no 7 <<< "$(printf 'conflict-sources\t%s\tx' "$SOURCES")"
    [ "$status" -eq 7 ]
    [ "$(cat "$SOURCES")" = "hand written" ]
}

@test "plan_execute reports a write it could not do" {
    rm -rf "$ROOT/etc/apt/sources.list.d"
    printf 'not a directory\n' > "$ROOT/etc/apt/sources.list.d"
    run plan_execute no 7 <<< "$(printf 'create-sources\t%s\tx' "$SOURCES")"
    [ "$status" -eq 5 ]
    run plan_execute no 7 <<< "$(printf 'create-pin\t%s/x/y\tx' "$ROOT/etc/apt/sources.list.d")"
    [ "$status" -eq 5 ]
}

@test "plan_execute reports a rename it could not do, in either direction" {
    run plan_execute no 7 <<< "$(printf 'disable-turnkey\t%s\tx' "$TMP/missing")"
    [ "$status" -eq 5 ]
    run plan_execute no 7 <<< "$(printf 'restore-turnkey\t%s\tx' "$TMP/missing")"
    [ "$status" -eq 7 ]
}

@test "plan_execute reports a removal it could not do, and ignores a keep" {
    mkdir "$TMP/adir"
    run plan_execute no 7 <<< "$(printf 'remove-pin\t%s\tx' "$TMP/adir")"
    [ "$status" -eq 5 ]
    run plan_execute no 7 <<< "$(printf 'keep-turnkey\t%s\tx' "$TMP/adir")"
    [ "$status" -eq 0 ]
}

@test "plan_execute removes only the files the tool wrote" {
    ours "$SOURCES"
    ours "$PREFS"
    plan_rollback | plan_execute no 7
    [ ! -e "$SOURCES" ]
    [ ! -e "$PREFS" ]
}
