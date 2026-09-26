#!/bin/bash
# shellcheck shell=bash
# The plan: what a phase would do, as records, and the two functions that
# print them and carry them out. A record is three tab separated fields,
# "operation<TAB>path<TAB>note", so the survey and the phase that runs
# print the same lines from the same code.
# Sourced by lib/transition.sh after lib/common.sh.

# render_line VERB PATH NOTE: one line of a plan or of a result.
render_line() {
    printf '  %-13s %-44s %s\n' "$1" "$2" "$3"
}

# plan_verb OP MODE: the word a record is reported with. MODE is "would"
# for the survey and "done" for a phase that ran.
plan_verb() {
    local verb
    case "${1%%-*}" in
        create) verb=create ;;
        update) verb=update ;;
        remove) verb=remove ;;
        disable | restore) verb=rename ;;
        keep) verb=keep ;;
        *) verb=refuse ;;
    esac
    if [ "$2" = would ] && [ "$verb" != keep ] && [ "$verb" != refuse ]; then
        printf 'would %s\n' "$verb"
    else
        printf '%s\n' "$verb"
    fi
}

# plan_render MODE: records on stdin, one reported line each on stdout.
plan_render() {
    local op path note
    while IFS=$'\t' read -r op path note; do
        render_line "$(plan_verb "$op" "$1")" "$path" "$note"
    done
}

# write_file PATH CONTENT: the file, mode 0644, with its directory. The
# content always ends in exactly one newline, so two runs of --apply leave
# byte identical files (idempotence).
write_file() {
    mkdir -p "$(dirname "$1")" || return 1
    printf '%s\n' "$2" > "$1" || return 1
    chmod 0644 "$1"
}

# plan_apply TRUSTED: the records --apply would carry out, in order.
plan_apply() {
    local sources prefs live note
    sources="$(rooted "$KEEL_SOURCES")"
    prefs="$(rooted "$KEEL_PREFS")"
    live="$(rooted "$KEEL_TURNKEY_LIST")"
    note="deb822, $KEEL_ARCHIVE_URI $KEEL_ARCHIVE_SUITE $KEEL_ARCHIVE_COMPONENTS"
    if [ "$1" = yes ]; then
        note="$note, Trusted: yes (unsigned)"
    else
        note="$note, Signed-By $KEEL_KEYRING_GPG"
    fi
    case "$(state_file "$sources")" in
        absent) printf 'create-sources\t%s\t%s\n' "$sources" "$note" ;;
        ours) printf 'update-sources\t%s\t%s\n' "$sources" "$note" ;;
        *) printf 'conflict-sources\t%s\t%s\n' "$sources" "not written by this tool: left untouched" ;;
    esac
    note="Pin: release o=$KEEL_PIN_ORIGIN at $KEEL_PIN_PRIORITY"
    case "$(state_file "$prefs")" in
        absent) printf 'create-pin\t%s\t%s\n' "$prefs" "$note" ;;
        ours) printf 'update-pin\t%s\t%s\n' "$prefs" "$note" ;;
        *) printf 'conflict-pin\t%s\t%s\n' "$prefs" "not written by this tool: left untouched" ;;
    esac
    case "$(state_turnkey)" in
        enabled) printf 'disable-turnkey\t%s\tto %s%s\n' "$live" "${KEEL_TURNKEY_LIST##*/}" "$KEEL_DISABLED_SUFFIX" ;;
        disabled) printf 'keep-turnkey\t%s\talready disabled by an earlier --apply\n' "$live$KEEL_DISABLED_SUFFIX" ;;
        both) printf 'conflict-turnkey\t%s\tboth names exist: rename one by hand\n' "$live" ;;
        *) printf 'keep-turnkey\t%s\tno upstream list on this machine\n' "$live" ;;
    esac
}

# plan_rollback: the records --rollback would carry out, undoing exactly
# what plan_apply did and nothing else.
plan_rollback() {
    local sources prefs live
    sources="$(rooted "$KEEL_SOURCES")"
    prefs="$(rooted "$KEEL_PREFS")"
    live="$(rooted "$KEEL_TURNKEY_LIST")"
    case "$(state_file "$sources")" in
        ours) printf 'remove-sources\t%s\tthe Keel archive is deconfigured\n' "$sources" ;;
        absent) printf 'keep-sources\t%s\tnot present\n' "$sources" ;;
        *) printf 'conflict-sources\t%s\tnot written by this tool: left untouched\n' "$sources" ;;
    esac
    case "$(state_file "$prefs")" in
        ours) printf 'remove-pin\t%s\tthe origin pin is removed\n' "$prefs" ;;
        absent) printf 'keep-pin\t%s\tnot present\n' "$prefs" ;;
        *) printf 'conflict-pin\t%s\tnot written by this tool: left untouched\n' "$prefs" ;;
    esac
    case "$(state_turnkey)" in
        disabled) printf 'restore-turnkey\t%s\tfrom %s%s, byte for byte\n' "$live" "${KEEL_TURNKEY_LIST##*/}" "$KEEL_DISABLED_SUFFIX" ;;
        both) printf 'conflict-turnkey\t%s\tboth names exist: rename one by hand\n' "$live" ;;
        enabled) printf 'keep-turnkey\t%s\talready enabled\n' "$live" ;;
        *) printf 'keep-turnkey\t%s\tno upstream list on this machine\n' "$live" ;;
    esac
}

# plan_execute TRUSTED CONFLICT_CODE: records on stdin, carried out in
# order. Returns 0, or the write code, or CONFLICT_CODE when a record is a
# refusal. Each record is reported by the caller through plan_render.
plan_execute() {
    local trusted="$1" conflict_code="$2" op path note rc=0
    while IFS=$'\t' read -r op path note; do
        case "$op" in
            create-sources | update-sources)
                write_file "$path" "$(sources_render "$KEEL_ARCHIVE_URI" \
                    "$KEEL_ARCHIVE_SUITE" "$KEEL_ARCHIVE_COMPONENTS" \
                    "$KEEL_KEYRING_GPG" "$trusted")" || rc=$EXIT_WRITE_FAILED ;;
            create-pin | update-pin)
                write_file "$path" "$(pin_render "$KEEL_PIN_ORIGIN" "$KEEL_PIN_PRIORITY")" ||
                    rc=$EXIT_WRITE_FAILED ;;
            disable-turnkey)
                mv "$path" "$path$KEEL_DISABLED_SUFFIX" || rc=$EXIT_WRITE_FAILED ;;
            restore-turnkey)
                mv "$path$KEEL_DISABLED_SUFFIX" "$path" || rc=$EXIT_ROLLBACK_INCOMPLETE ;;
            remove-sources | remove-pin)
                rm -f "$path" || rc=$EXIT_WRITE_FAILED ;;
            conflict-*) rc="$conflict_code" ;;
            *) : ;;
        esac
    done
    return "$rc"
}

