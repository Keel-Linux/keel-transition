#!/usr/bin/env bats
# lib/common.sh: the paths, the state of each file the tool owns, and the
# rendering of the two files it writes.

load helpers

bats_require_minimum_version 1.5.0

setup() {
    scratch_setup
    . "$REPO/lib/transition.sh"
    KEEL_ROOT="$ROOT"
}
teardown() { scratch_teardown; }

@test "rooted prefixes every path with the root, and nothing when it is the live system" {
    [ "$(rooted /etc/apt)" = "$ROOT/etc/apt" ]
    KEEL_ROOT=""
    [ "$(rooted /etc/apt)" = "/etc/apt" ]
}

@test "log writes one prefixed line on stderr" {
    run --separate-stderr bash -c ". $REPO/lib/transition.sh; log 'a message'"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    [ "$stderr" = "keel-transition: a message" ]
}

@test "pin_render is the release pin at 1001, the same file the apt tooling renders" {
    run pin_render "Keel Linux" 1001
    [ "$status" -eq 0 ]
    [ "${lines[2]}" = "Package: *" ]
    [ "${lines[3]}" = "Pin: release o=Keel Linux" ]
    [ "${lines[4]}" = "Pin-Priority: 1001" ]
}

@test "pin_render takes another origin and priority" {
    run pin_render "Other" 990
    [ "${lines[3]}" = "Pin: release o=Other" ]
    [ "${lines[4]}" = "Pin-Priority: 990" ]
}

@test "sources_render writes a deb822 stanza signed by the keyring" {
    run sources_render https://archive.keellinux.org trixie main /usr/share/keyrings/k.gpg no
    [ "$status" -eq 0 ]
    [[ "$output" == *"Types: deb"* ]]
    [[ "$output" == *"URIs: https://archive.keellinux.org"* ]]
    [[ "$output" == *"Suites: trixie"* ]]
    [[ "$output" == *"Components: main"* ]]
    [[ "$output" == *"Signed-By: /usr/share/keyrings/k.gpg"* ]]
    [[ "$output" != *"Trusted:"* ]]
}

@test "sources_render with trusted adds Trusted: yes and says why that is dangerous" {
    run sources_render https://archive.keellinux.org trixie main /usr/share/keyrings/k.gpg yes
    [[ "$output" == *"Trusted: yes"* ]]
    [[ "$output" == *"Signature checking is off"* ]]
}

@test "file_is_ours is true only for a file carrying the marker" {
    printf 'nothing of ours\n' > "$TMP/foreign"
    printf '# %s as x\n' "$KEEL_MARKER" > "$TMP/ours"
    run file_is_ours "$TMP/ours"
    [ "$status" -eq 0 ]
    run file_is_ours "$TMP/foreign"
    [ "$status" -ne 0 ]
    run file_is_ours "$TMP/missing"
    [ "$status" -ne 0 ]
}

@test "state_file reports absent, ours and foreign" {
    [ "$(state_file "$TMP/missing")" = absent ]
    printf '# %s\n' "$KEEL_MARKER" > "$TMP/ours"
    [ "$(state_file "$TMP/ours")" = ours ]
    printf 'hand written\n' > "$TMP/foreign"
    [ "$(state_file "$TMP/foreign")" = foreign ]
}

@test "state_turnkey reports absent, enabled, disabled and both" {
    [ "$(state_turnkey)" = absent ]
    turnkey_list
    [ "$(state_turnkey)" = enabled ]
    mv "$ROOT/etc/apt/sources.list.d/turnkey.list" \
        "$ROOT/etc/apt/sources.list.d/turnkey.list.disabled-by-keel"
    [ "$(state_turnkey)" = disabled ]
    turnkey_list
    [ "$(state_turnkey)" = both ]
}

@test "keyring_fingerprint reads the file the keyring package installs" {
    install_keyring
    [ "$(keyring_fingerprint)" = AD0964BE3F09DED469A3B6B2148E951314703180 ]
}

@test "keyring_fingerprint fails when the keyring package is not installed" {
    run keyring_fingerprint
    [ "$status" -ne 0 ]
    [ "$output" = "" ]
}

@test "write_file creates the directory, the file and mode 0644" {
    run write_file "$TMP/a/b/c" "one
two"
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/a/b/c")" = "one
two" ]
    [ "$(stat -c %a "$TMP/a/b/c")" = 644 ]
}

@test "write_file ends the file with exactly one newline, so two runs are byte identical" {
    write_file "$TMP/f" "x"
    cp "$TMP/f" "$TMP/first"
    write_file "$TMP/f" "x"
    cmp "$TMP/first" "$TMP/f"
    [ "$(wc -l < "$TMP/f")" -eq 1 ]
}

@test "write_file fails when a parent of the path is a regular file" {
    printf 'not a directory\n' > "$TMP/blocked"
    run write_file "$TMP/blocked/file" "x"
    [ "$status" -ne 0 ]
}

@test "write_file fails when the path is a directory" {
    mkdir "$TMP/adir"
    run write_file "$TMP/adir" "x"
    [ "$status" -ne 0 ]
}

@test "needs_root is true only on the live system as a normal user" {
    stub id 'echo 1000'
    KEEL_ROOT=""
    run needs_root
    [ "$status" -eq 0 ]
    KEEL_ROOT="$ROOT"
    run needs_root
    [ "$status" -ne 0 ]
    KEEL_ROOT=""
    stub id 'echo 0'
    run needs_root
    [ "$status" -ne 0 ]
}

@test "turnkey_sources finds the deb822 files that carry a TurnKey stanza" {
    cat > "$ROOT/etc/apt/sources.list.d/sources.sources" << SRC
Types: deb
URIs: http://archive.turnkeylinux.org/debian
Suites: trixie
Components: main
Signed-By: /usr/share/keyrings/tkl-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main non-free-firmware
SRC
    cat > "$ROOT/etc/apt/sources.list.d/debian-backports.sources" << SRC
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
SRC
    run turnkey_sources
    [ "$status" -eq 0 ]
    [ "$output" = "$ROOT/etc/apt/sources.list.d/sources.sources" ]
}

@test "turnkey_sources is empty on a machine with none, and when the directory is gone" {
    run turnkey_sources
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    rm -r "$ROOT/etc/apt/sources.list.d"
    run turnkey_sources
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}
