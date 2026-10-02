#!/usr/bin/env bats
# A TurnKey 19.0 appliance keeps its upstream archive in deb822 files shared
# with Debian (sources.sources, security.sources.sources), plus
# turnkey-testing.sources, an /etc/apt/preferences that pins
# o=turnkeylinux at 999, and turnkey-keys. --apply replaces the shared
# files with Debian's own, sets the TurnKey files and pin aside, purges
# turnkey-keys, and --rollback puts every one of them back. Nothing may
# ever be downgraded: the Keel pin is 990, below 1000 (tracker#23).

load helpers

bats_require_minimum_version 1.5.0

setup() {
    scratch_setup
    install_keyring
    stub_keel
    stub_curl_absent
    D="$ROOT/etc/apt/sources.list.d"
    PREFS="$ROOT/etc/apt/preferences.d/keel"
    DEBIAN="$D/debian.sources"
    SECURITY="$D/security.sources"
    TKPREFS="$ROOT/etc/apt/preferences"
    turnkey19_tree
    stub_dpkg
}
teardown() { scratch_teardown; }

# turnkey19_tree: the apt files TurnKey's 19.0 bootstrap writes
turnkey19_tree() {
    cat > "$D/sources.sources" << SRC
Types: deb
URIs: https://archive.turnkeylinux.org/debian
Suites: trixie
Components: main
Architectures: amd64 arm64
Enabled: yes
Signed-By: /usr/share/keyrings/tkl-archive-keyring.gpg

Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie
Components: main contrib non-free-firmware
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
    cat > "$D/security.sources.sources" << SRC
Types: deb
URIs: https://archive.turnkeylinux.org/debian
Suites: trixie-security
Components: main
Enabled: yes
Signed-By: /usr/share/keyrings/tkl-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free-firmware
Enabled: yes
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
    cat > "$D/turnkey-testing.sources" << SRC
Types: deb
URIs: https://archive.turnkeylinux.org/debian
Suites: trixie-testing
Components: main
Enabled: no
Signed-By: /usr/share/keyrings/tkl-archive-keyring.gpg
SRC
    printf 'Package: *\nPin: release o=turnkeylinux\nPin-Priority: 999\n\n' > "$TKPREFS"
    printf 'tkl archive keyring\n' > "$ROOT/usr/share/keyrings/tkl-archive-keyring.gpg"
    printf 'tkl trixie main key\n' > "$ROOT/usr/share/keyrings/tkl-trixie-main.asc"
    cp -a "$ROOT/etc/apt" "$TMP/apt.original"
    cp -a "$ROOT/usr/share/keyrings" "$TMP/keyrings.original"
}

# stub_dpkg: dpkg-query answers from $TMP/pkgs ("name status version"),
# lists turnkey-keys' files, and dpkg -P turnkey-keys removes them as the
# real one would. Every dpkg call is recorded.
stub_dpkg() {
    printf 'turnkey-keys installed 0.1\nkeel-archive-keyring installed 0.1.1\n' > "$TMP/pkgs"
    printf '/.\n/usr\n/usr/share/keyrings\n/usr/share/keyrings/tkl-archive-keyring.gpg\n/usr/share/keyrings/tkl-trixie-main.asc\n' \
        > "$TMP/turnkey-keys.list"
    stub dpkg-query "case \" \$* \" in
*' -L '*) [ \"\${@: -1}\" = turnkey-keys ] && grep -q '^turnkey-keys ' '$TMP/pkgs' && exec cat '$TMP/turnkey-keys.list'; exit 1 ;;
esac
line=\"\$(awk -v n=\"\${@: -1}\" '\$1 == n { print \$2, \$3 }' '$TMP/pkgs')\"
[ -n \"\$line\" ] || exit 1
echo \"\$line\""
    stub dpkg "echo \"\$*\" >> '$TMP/dpkg.calls'
if [ \"\${@: -1}\" = turnkey-keys ] && [[ \" \$* \" == *' -P '* ]]; then
    rm -f '$ROOT/usr/share/keyrings/tkl-archive-keyring.gpg' '$ROOT/usr/share/keyrings/tkl-trixie-main.asc'
    sed -i '/^turnkey-keys /d' '$TMP/pkgs'
fi"
}

apply() { run "$REPO/bin/keel-transition" --apply --force-unsigned --no-inspect --root "$ROOT"; }
rollback() { run "$REPO/bin/keel-transition" --rollback --root "$ROOT"; }

# the hosts apt would fetch from with what is in the scratch tree
fetch_hosts() {
    mkdir -p "$TMP/aptstate/lists/partial" "$TMP/aptstate/dpkg"
    : > "$TMP/aptstate/dpkg/status"
    # $(URI) is apt's format field
    # shellcheck disable=SC2016
    apt-get -o Dir::Etc="$ROOT/etc/apt" -o Dir::State="$TMP/aptstate" \
        -o Dir::State::status="$TMP/aptstate/dpkg/status" \
        indextargets --no-release-info --format '$(URI)' \
        | sed -E 's|^[a-z]+://([^/]+)/.*|\1|' | sort -u
}

@test "--apply replaces TurnKey's deb822 files with Debian's own" {
    apply
    [ "$status" -eq 0 ]
    grep -qx 'URIs: http://deb.debian.org/debian' "$DEBIAN"
    grep -qx 'Suites: trixie trixie-updates' "$DEBIAN"
    grep -qx 'URIs: http://security.debian.org/debian-security' "$SECURITY"
    grep -qx 'Suites: trixie-security' "$SECURITY"
    # the components the appliance had, contrib included
    grep -qx 'Components: main contrib non-free-firmware' "$DEBIAN"
    grep -qx 'Components: main contrib non-free-firmware' "$SECURITY"
    grep -qx 'Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg' "$DEBIAN"
    grep -qF 'Installed by keel-transition' "$DEBIAN"
    grep -qF 'Installed by keel-transition' "$SECURITY"
    local f
    for f in sources.sources security.sources.sources turnkey-testing.sources; do
        [ ! -e "$D/$f" ]
        cmp "$TMP/apt.original/sources.list.d/$f" "$D/$f.disabled-by-keel"
    done
}

@test "--apply sets TurnKey's 999 pin aside and pins Keel at 990" {
    apply
    [ "$status" -eq 0 ]
    [ ! -e "$TKPREFS" ]
    cmp "$TMP/apt.original/preferences" "$TKPREFS.disabled-by-keel"
    grep -qx 'Pin-Priority: 990' "$PREFS"
}

@test "after --apply apt reads Debian, Debian security and the Keel archive only" {
    apply
    [ "$status" -eq 0 ]
    run fetch_hosts
    [ "$output" = "$(printf 'archive.keellinux.org\ndeb.debian.org\nsecurity.debian.org')" ]
}

@test "--apply purges turnkey-keys through dpkg and keeps its files for --rollback" {
    apply
    [ "$status" -eq 0 ]
    [ "$(cat "$TMP/dpkg.calls")" = "--root=$ROOT -P turnkey-keys" ]
    [ ! -e "$ROOT/usr/share/keyrings/tkl-archive-keyring.gpg" ]
    tar -tf "$ROOT/var/lib/keel/transition/turnkey-keys.tar" | grep -qx 'usr/share/keyrings/tkl-archive-keyring.gpg'
    [[ "$output" == *"purge"*"turnkey-keys"* ]]
    [[ "$output" == *"no package was installed or upgraded"* ]]
}

@test "--rollback puts every file back, byte for byte, and says how to reinstall turnkey-keys" {
    apply
    [ "$status" -eq 0 ]
    rollback
    [ "$status" -eq 0 ]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$output" = "" ]
    run diff -r "$TMP/keyrings.original" "$ROOT/usr/share/keyrings"
    [ "$output" = "" ]
    [ ! -e "$ROOT/var/lib/keel/transition/turnkey-keys.tar" ]
    # a second rollback has nothing left to do
    rollback
    [ "$status" -eq 0 ]
    run diff -r "$TMP/apt.original" "$ROOT/etc/apt"
    [ "$output" = "" ]
}

@test "--rollback says the turnkey-keys record has to be reinstalled" {
    apply
    rollback
    [[ "$output" == *"apt-get install turnkey-keys"* ]]
}

@test "--apply twice leaves the same bytes" {
    apply
    [ "$status" -eq 0 ]
    cp "$DEBIAN" "$TMP/debian.first"
    cp "$SECURITY" "$TMP/security.first"
    apply
    [ "$status" -eq 0 ]
    cmp "$TMP/debian.first" "$DEBIAN"
    cmp "$TMP/security.first" "$SECURITY"
    [ "$(wc -l < "$TMP/dpkg.calls")" -eq 1 ]
}

@test "an operator's stanza in /etc/apt/preferences is a refusal, and nothing is purged" {
    printf 'Package: foo\nPin: release a=trixie-backports\nPin-Priority: 500\n' >> "$TKPREFS"
    cp "$TKPREFS" "$TMP/prefs.mine"
    apply
    [ "$status" -eq 5 ]
    cmp "$TMP/prefs.mine" "$TKPREFS"
    [[ "$output" == *"refuse"*"/etc/apt/preferences"* ]]
    [ ! -e "$TMP/dpkg.calls" ]
}

@test "a TurnKey stanza in a file the tool does not know is a refusal, and nothing is purged" {
    printf 'Types: deb\nURIs: https://archive.turnkeylinux.org/debian\nSuites: trixie\nComponents: main\n' \
        > "$D/vendor.sources"
    apply
    [ "$status" -eq 5 ]
    [[ "$output" == *"refuse"*"vendor.sources"* ]]
    [ -f "$D/vendor.sources" ]
    [ ! -e "$TMP/dpkg.calls" ]
}

@test "a debian.sources somebody else wrote keeps TurnKey's shared files in place" {
    printf 'hand written\n' > "$DEBIAN"
    apply
    [ "$status" -eq 5 ]
    [ "$(cat "$DEBIAN")" = "hand written" ]
    [ -f "$D/sources.sources" ]
    [ ! -e "$D/sources.sources.disabled-by-keel" ]
    [ ! -e "$TMP/dpkg.calls" ]
}

# --------------------------------------------------- never downgrade, in apt

# make_archive NAME ORIGIN PKG=VER...: a local archive carrying ORIGIN
make_archive() {
    local name="$1" origin="$2" spec dir
    shift 2
    dir="$TMP/archives/$name"
    mkdir -p "$dir/dists/trixie/main/binary-amd64"
    for spec in "$@"; do
        printf 'Package: %s\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@example.org>\nFilename: pool/x.deb\nSize: 1\nSHA256: %064d\nDescription: x\n\n' \
            "${spec%%=*}" "${spec#*=}" 0 >> "$dir/dists/trixie/main/binary-amd64/Packages"
    done
    (cd "$dir/dists/trixie" && apt-ftparchive -o APT::FTPArchive::Release::Origin="$origin" \
        -o APT::FTPArchive::Release::Suite=trixie -o APT::FTPArchive::Release::Codename=trixie \
        release . > Release)
    printf 'Types: deb\nURIs: file:%s\nSuites: trixie\nComponents: main\nTrusted: yes\n' "$dir" \
        > "$TMP/policy/etc/apt/sources.list.d/$name.sources"
}

@test "with the pin --apply writes, apt upgrades to Keel's build and never goes back" {
    apply
    [ "$status" -eq 0 ]
    mkdir -p "$TMP/policy/etc/apt/sources.list.d" "$TMP/policy/etc/apt/preferences.d" \
        "$TMP/policy/lists/partial" "$TMP/policy/dpkg"
    cp "$PREFS" "$TMP/policy/etc/apt/preferences.d/keel"
    make_archive debian Debian rebuilt=1.2-1
    make_archive keel "Keel Linux" inithooks=2.3.6+keel5 confconsole=2.2.3+keel2 rebuilt=1.1-1+keel1
    # installed: TurnKey's inithooks, a confconsole newer than the archive's
    printf 'Package: %s\nStatus: install ok installed\nVersion: %s\nArchitecture: amd64\nMaintainer: t <t@example.org>\nDescription: x\n\n' \
        inithooks 2.3.6 confconsole 2.2.3+keel11 rebuilt 1.1-1+keel1 > "$TMP/policy/dpkg/status"
    local o=(-o Dir::Etc="$TMP/policy/etc/apt" -o Dir::State="$TMP/policy"
        -o Dir::State::status="$TMP/policy/dpkg/status" -o Dir::Cache="$TMP/policy")
    apt-get "${o[@]}" update -qq 2> /dev/null
    run apt-get "${o[@]}" -s dist-upgrade
    [ "$status" -eq 0 ]
    [[ "$output" == *"Inst inithooks [2.3.6] (2.3.6+keel5 "* ]]
    [[ "$output" != *DOWNGRADED* ]]
    [[ "$output" != *"Inst confconsole"* ]]
    [[ "$output" != *"Inst rebuilt"* ]]
}

@test "with no Debian stanza to copy, Debian's sources take trixie and main non-free-firmware" {
    rm "$D/sources.sources" "$D/security.sources.sources"
    apply
    [ "$status" -eq 0 ]
    grep -qx 'Suites: trixie trixie-updates' "$DEBIAN"
    grep -qx 'Components: main non-free-firmware' "$DEBIAN"
    grep -qx 'Suites: trixie-security' "$SECURITY"
    grep -qx 'Components: main non-free-firmware' "$SECURITY"
    [ -f "$D/turnkey-testing.sources.disabled-by-keel" ]
}
