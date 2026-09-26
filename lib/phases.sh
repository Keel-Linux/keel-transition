#!/bin/bash
# shellcheck shell=bash
# The three phases, the survey of the instance spec they share, and the
# argument parsing. Sourced by lib/transition.sh last.

# needs_root: true when the operation would write to the live system and
# the caller is not root. With --root DIR there is nothing privileged to do.
needs_root() {
    [ -z "$KEEL_ROOT" ] && [ "$(id -u)" -ne 0 ]
}

# survey_run: keel inspect into the spec (only when the spec is absent) and
# into the report. The only files the survey writes.
survey_run() {
    local spec report tmp rc=0 keelrc=0
    local -a args
    spec="$(rooted "$KEEL_SPEC")"
    report="$(rooted "$KEEL_REPORT")"
    command -v keel > /dev/null 2>&1 || return "$EXIT_KEEL_MISSING"
    mkdir -p "$(dirname "$spec")" "$(dirname "$report")" || return "$EXIT_WRITE_FAILED"
    args=(inspect --report "$report")
    if [ -n "$KEEL_ROOT" ]; then
        args+=(--root "$KEEL_ROOT")
    fi
    if [ -e "$spec" ]; then
        tmp="$(mktemp)"
        keel "${args[@]}" --output "$tmp" > /dev/null || keelrc=$?
        rm -f "$tmp"
        render_line keep "$spec" "already present: inspect ran, the file was not rewritten"
    else
        keel "${args[@]}" --output "$spec" > /dev/null || keelrc=$?
        render_line write "$spec" "written by keel inspect"
    fi
    render_line report "$report" "every field, with its source or why it is missing"
    if [ "$keelrc" -eq 13 ]; then
        rc="$EXIT_SURVEY_INCOMPLETE"
    elif [ "$keelrc" -eq 5 ]; then
        rc="$EXIT_WRITE_FAILED"
    elif [ "$keelrc" -ne 0 ]; then
        rc="$EXIT_SURVEY_INCOMPLETE"
        log "keel inspect exited $keelrc"
    fi
    return "$rc"
}

# survey_gaps REPORT: the lines of the report that name what could not be
# inferred, plus the summary line, indented under the spec section.
survey_gaps() {
    local gaps
    if [ ! -r "$1" ]; then
        printf '  no report at %s\n' "$1"
        return 0
    fi
    gaps="$(grep -E 'not inferred|not extracted' "$1" | grep -v '^inspect: ')" || gaps=""
    if [ -n "$gaps" ]; then
        printf '  could not infer, or will not read:\n'
        printf '%s\n' "$gaps" | sed 's/^/    /'
    else
        printf '  every field was inferred\n'
    fi
    grep -E '^inspect: ' "$1" | sed 's/^/  /' || true
}

# warn_unsigned: what --force-unsigned costs, in words, before it is done.
warn_unsigned() {
    log "WARNING: --force-unsigned: $ARCHIVE_REASON"
    log "WARNING: the source will carry Trusted: yes, so apt will install"
    log "WARNING: packages from $KEEL_ARCHIVE_URI without verifying any"
    log "WARNING: signature. Whatever can answer for that name, and any proxy"
    log "WARNING: on the way, can then install code that runs as root on this"
    log "WARNING: appliance. Use it on a test bench, never on a live one."
}

# archive_state: run archive_verify in a scratch directory and report the
# one line the survey and apply both print. Returns what archive_verify did.
archive_state() {
    local dir rc=0 fpr
    dir="$(mktemp -d)"
    archive_verify "$KEEL_ARCHIVE_URI" "$KEEL_ARCHIVE_SUITE" \
        "$(rooted "$KEEL_KEYRING_GPG")" "$dir" || rc=$?
    rm -rf "$dir"
    if [ "$rc" -eq 0 ]; then
        render_line verified "$KEEL_ARCHIVE_URI" "$ARCHIVE_REASON"
    else
        render_line unverified "$KEEL_ARCHIVE_URI" "$ARCHIVE_REASON"
    fi
    fpr="$(keyring_fingerprint)" || fpr=""
    if [ -n "$fpr" ]; then
        render_line keyring "$(rooted "$KEEL_KEYRING_GPG")" "key $fpr"
    else
        render_line keyring "$(rooted "$KEEL_KEYRING_GPG")" "no fingerprint file: keel-archive-keyring is not installed"
    fi
    return "$rc"
}

# phase_survey INSPECT: phase 1, the default. Changes nothing under /etc/apt.
phase_survey() {
    local rc=0 av=0 plan
    printf '%s %s: survey. Nothing under %s is changed.\n\n' \
        "$PROG" "$KEEL_TRANSITION_VERSION" "$(rooted /etc/apt)"
    printf 'Instance spec\n'
    if [ "$1" = yes ]; then
        survey_run || rc=$?
        if [ "$rc" -eq "$EXIT_KEEL_MISSING" ]; then
            render_line skip "$(rooted "$KEEL_SPEC")" "the keel command is not installed: no spec was written"
        else
            survey_gaps "$(rooted "$KEEL_REPORT")"
        fi
    else
        render_line skip "$(rooted "$KEEL_SPEC")" "--no-inspect: the spec was not touched"
    fi
    printf '\nArchive\n'
    archive_state || av=$?
    printf '\nWhat --apply would change\n'
    plan="$(plan_apply no)"
    printf '%s\n' "$plan" | plan_render would
    printf '\n'
    if [ "$av" -ne 0 ]; then
        printf '%s: --apply would refuse today, exit %s: %s\n' \
            "$PROG" "$EXIT_ARCHIVE_UNSIGNED" "$ARCHIVE_REASON"
    fi
    printf '%s: undo anything --apply does with: keel-transition --rollback\n' "$PROG"
    return "$rc"
}

# phase_apply FORCE INSPECT: phase 2. Refuses before changing anything when
# the archive has no Release the keyring verifies.
phase_apply() {
    local force="$1" trusted=no rc=0 av=0 plan
    printf '%s %s: apply.\n\n' "$PROG" "$KEEL_TRANSITION_VERSION"
    printf 'Archive\n'
    archive_state || av=$?
    if [ "$av" -eq 3 ]; then
        log "refusing --apply: $ARCHIVE_REASON. Nothing was changed."
        return "$EXIT_KEYRING_MISSING"
    fi
    if [ "$av" -ne 0 ]; then
        if [ "$force" != yes ]; then
            log "refusing --apply: $ARCHIVE_REASON"
            log "an archive nothing signs would let whatever answers for that name install code as root here, so it is never enabled silently."
            log "nothing was changed. Re-run with --force-unsigned to accept that risk explicitly."
            return "$EXIT_ARCHIVE_UNSIGNED"
        fi
        trusted=yes
        warn_unsigned
    elif [ "$force" = yes ]; then
        log "--force-unsigned ignored: the archive verifies, so the source keeps its signature check."
    fi
    printf '\nInstance spec\n'
    if [ "$2" = yes ]; then
        survey_run || rc=$?
        if [ "$rc" -eq "$EXIT_KEEL_MISSING" ]; then
            render_line skip "$(rooted "$KEEL_SPEC")" "the keel command is not installed: no spec was written"
            rc=0
        fi
    else
        render_line skip "$(rooted "$KEEL_SPEC")" "--no-inspect: the spec was not touched"
    fi
    printf '\nApt configuration\n'
    plan="$(plan_apply "$trusted")"
    printf '%s\n' "$plan" | plan_execute "$trusted" "$EXIT_WRITE_FAILED" || rc=$?
    printf '%s\n' "$plan" | plan_render "done"
    printf '\n'
    printf '%s: no package was installed, upgraded or removed. Run apt-get update yourself.\n' "$PROG"
    printf '%s: undo all of it with: keel-transition --rollback\n' "$PROG"
    return "$rc"
}

# phase_rollback: phase 3. Undoes exactly what --apply did, and nothing else.
phase_rollback() {
    local rc=0 plan
    printf '%s %s: rollback.\n\n' "$PROG" "$KEEL_TRANSITION_VERSION"
    printf 'Apt configuration\n'
    plan="$(plan_rollback)"
    printf '%s\n' "$plan" | plan_execute no "$EXIT_ROLLBACK_INCOMPLETE" || rc=$?
    printf '%s\n' "$plan" | plan_render "done"
    printf '\n'
    render_line keep "$(rooted "$KEEL_SPEC")" "the spec the survey wrote is yours: remove it by hand if you want it gone"
    printf '%s: no package was installed, upgraded or removed.\n' "$PROG"
    return "$rc"
}

# usage: the help text, which says in full what the tool does not do.
usage() {
    cat << USAGE
usage: keel-transition [--apply | --rollback] [options]

Moves a TurnKey Linux 19.0 appliance onto the Keel Linux archive, in three
phases. Each one is reversible and each one reports every file it touches.

  (no option)  survey: run keel inspect, write $KEEL_SPEC when it is
               absent, report what it could not infer, and print what
               --apply would change. Nothing under /etc/apt is changed.
  --apply      write $KEEL_SOURCES (deb822, Signed-By
               $KEEL_KEYRING_GPG), write $KEEL_PREFS
               (Pin: release o=$KEEL_PIN_ORIGIN, Pin-Priority $KEEL_PIN_PRIORITY),
               and disable $KEEL_TURNKEY_LIST by renaming it
               to <name>$KEEL_DISABLED_SUFFIX.
  --rollback   undo exactly that: the upstream list is renamed back, byte
               for byte, and the sources and the pin are removed.

This tool never touches a package. It does not run apt-get, and it
installs, upgrades and removes nothing. It changes apt sources, one
preferences file and the instance spec. Running apt-get update, and
deciding what to install afterwards, stays with the operator.

--apply refuses, with exit $EXIT_ARCHIVE_UNSIGNED, when the archive has no
Release that $KEEL_KEYRING_GPG verifies. It checks; it never assumes.

options:
  --force-unsigned    enable the archive all the same, with Trusted: yes,
                      after printing what that costs. Test benches only.
  --root DIR          work on this filesystem tree instead of /
  --archive-uri URL   default $KEEL_ARCHIVE_URI
  --suite NAME        default $KEEL_ARCHIVE_SUITE
  --components LIST   default $KEEL_ARCHIVE_COMPONENTS
  --spec FILE         instance spec, default $KEEL_SPEC
  --report FILE       survey report, default $KEEL_REPORT
  --no-inspect        do not run keel inspect; survey the apt state only
  -h, --help          this text
  --version           print the version and exit

exit codes: 0 ok; 1 usage; 2 must run as root; 3 keel inspect could not
infer a required field; 4 the archive has no verifiable signed Release;
5 a file could not be written; 6 the archive keyring is missing;
7 rollback left something behind; 8 the keel command is not installed.

See keel-transition(8) and https://github.com/keel-linux/keel-transition
USAGE
}

# opt_set OPTION VALUE: the one place an option name maps to its variable.
opt_set() {
    local name
    case "$1" in
        --root) name=KEEL_ROOT ;;
        --archive-uri) name=KEEL_ARCHIVE_URI ;;
        --suite) name=KEEL_ARCHIVE_SUITE ;;
        --components) name=KEEL_ARCHIVE_COMPONENTS ;;
        --spec) name=KEEL_SPEC ;;
        *) name=KEEL_REPORT ;;
    esac
    printf -v "$name" '%s' "$2"
}

# transition_main ARGS: parse, check, dispatch. The executable is this call
# and nothing else (decision 0004).
transition_main() {
    local mode=survey force=no inspect=yes
    while [ $# -gt 0 ]; do
        case "$1" in
            --apply) mode=apply; shift ;;
            --rollback) mode=rollback; shift ;;
            --force-unsigned) force=yes; shift ;;
            --no-inspect) inspect=no; shift ;;
            --root | --archive-uri | --suite | --components | --spec | --report)
                if [ $# -lt 2 ]; then
                    log "$1 needs a value"
                    return "$EXIT_USAGE"
                fi
                opt_set "$1" "$2"
                shift 2 ;;
            -h | --help) usage; return "$EXIT_OK" ;;
            --version) printf '%s %s\n' "$PROG" "$KEEL_TRANSITION_VERSION"; return "$EXIT_OK" ;;
            *)
                log "unknown argument: $1"
                log "try: keel-transition --help"
                return "$EXIT_USAGE" ;;
        esac
    done
    if [ "$force" = yes ] && [ "$mode" != apply ]; then
        log "--force-unsigned means nothing without --apply"
        return "$EXIT_USAGE"
    fi
    if [ "$mode" != survey ] && needs_root; then
        log "$mode changes /etc/apt on the live system: run it as root, or pass --root DIR"
        return "$EXIT_NEEDS_ROOT"
    fi
    case "$mode" in
        apply) phase_apply "$force" "$inspect" ;;
        rollback) phase_rollback ;;
        *) phase_survey "$inspect" ;;
    esac
}
