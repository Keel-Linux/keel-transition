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
        purge) verb=purge ;;
        unpack) verb=restore ;;
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
# turnkey-keys is purged last, and only when nothing was refused: a refused
# file may still name the TurnKey archive, which needs its key.
plan_apply() {
    local records
    records="$(plan_apply_keel "$1"; plan_apply_turnkey)"
    if grep -q '^conflict-' <<< "$records"; then
        # a whole line of a multi-line value, anchored: sed, not ${//}
        # shellcheck disable=SC2001
        records="$(sed 's/^purge-turnkeykeys\tturnkey-keys\t.*/keep-turnkeykeys\tturnkey-keys\tkept: a refusal above/' <<< "$records")"
    fi
    printf '%s\n' "$records"
}

# plan_apply_keel TRUSTED: the Keel source, the pin and turnkey.list.
plan_apply_keel() {
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

# plan_apply_debian: Debian's own sources, in place of TurnKey's shared
# deb822 files, and those files set aside only when Debian's could be
# written, so Debian is never left without a source.
plan_apply_debian() {
    local kind path written=yes name live
    turnkey_deb822_any || return 0
    for kind in debian security; do
        if [ "$kind" = debian ]; then path="$(rooted "$KEEL_DEBIAN_SOURCES")"; else path="$(rooted "$KEEL_SECURITY_SOURCES")"; fi
        case "$(state_file "$path")" in
            absent) printf 'create-%s\t%s\tdeb822, Debian, Signed-By %s\n' "$kind" "$path" "$KEEL_DEBIAN_KEYRING" ;;
            ours) printf 'update-%s\t%s\tdeb822, Debian, Signed-By %s\n' "$kind" "$path" "$KEEL_DEBIAN_KEYRING" ;;
            *) printf 'conflict-%s\t%s\tnot written by this tool: left untouched\n' "$kind" "$path"; written=no ;;
        esac
    done
    for name in $KEEL_TURNKEY_DEB822; do
        live="$(turnkey_deb822_path "$name")"
        if [ -e "$live" ] && [ -e "$live$KEEL_DISABLED_SUFFIX" ]; then
            printf 'conflict-tkfile\t%s\tboth names exist: rename one by hand\n' "$live"
        elif [ -e "$live" ] && [ "$written" = yes ]; then
            printf 'disable-tkfile\t%s\tto %s%s\n' "$live" "$name" "$KEEL_DISABLED_SUFFIX"
        elif [ -e "$live" ]; then
            printf 'conflict-tkfile\t%s\tkept: Debian'"'"'s sources could not be written\n' "$live"
        elif [ -e "$live$KEEL_DISABLED_SUFFIX" ]; then
            printf 'keep-tkfile\t%s\talready set aside by an earlier --apply\n' "$live$KEEL_DISABLED_SUFFIX"
        fi
    done
}

# plan_apply_turnkey: the rest of what TurnKey leaves, then turnkey-keys,
# which is purged only when nothing above was refused.
plan_apply_turnkey() {
    local records file prefs
    records="$(plan_apply_debian)"
    while read -r file; do
        [ -n "$file" ] || continue
        records="$records"$'\n'"$(printf 'conflict-tksource\t%s\ta TurnKey stanza in a file this tool does not know: disable it by hand' "$file")"
    done <<< "$(turnkey_sources_unknown)"
    prefs="$(rooted "$KEEL_TURNKEY_PREFS")"
    if [ -e "$prefs" ] && grep -q 'o=turnkeylinux' "$prefs"; then
        if [ -e "$prefs$KEEL_DISABLED_SUFFIX" ]; then
            records="$records"$'\n'"$(printf 'conflict-tkpin\t%s\tboth names exist: rename one by hand' "$prefs")"
        elif turnkey_pin_only "$prefs"; then
            records="$records"$'\n'"$(printf 'disable-tkpin\t%s\tthe o=turnkeylinux pin, to %s%s' "$prefs" "${KEEL_TURNKEY_PREFS##*/}" "$KEEL_DISABLED_SUFFIX")"
        else
            records="$records"$'\n'"$(printf 'conflict-tkpin\t%s\tholds other pins too: remove the o=turnkeylinux stanza by hand' "$prefs")"
        fi
    elif [ -e "$prefs$KEEL_DISABLED_SUFFIX" ]; then
        records="$records"$'\n'"$(printf 'keep-tkpin\t%s\talready set aside by an earlier --apply' "$prefs$KEEL_DISABLED_SUFFIX")"
    fi
    case "$(turnkey_keys_state)" in
        installed | config-files | half-installed | unpacked | half-configured)
            records="$records"$'\n'"$(printf 'purge-turnkeykeys\tturnkey-keys\tdpkg -P, its files kept in %s for --rollback' "$(turnkey_keys_saved)")" ;;
    esac
    sed '/^$/d' <<< "$records"
}

# plan_rollback_turnkey: undo plan_apply_turnkey, file by file.
plan_rollback_turnkey() {
    local kind path name live prefs
    for kind in debian security; do
        if [ "$kind" = debian ]; then path="$(rooted "$KEEL_DEBIAN_SOURCES")"; else path="$(rooted "$KEEL_SECURITY_SOURCES")"; fi
        [ "$(state_file "$path")" = ours ] && printf 'remove-%s\t%s\tDebian'"'"'s source this tool wrote\n' "$kind" "$path"
    done
    for name in $KEEL_TURNKEY_DEB822 "${KEEL_TURNKEY_PREFS#/}"; do
        if [ "$name" = "${KEEL_TURNKEY_PREFS#/}" ]; then live="$(rooted "$KEEL_TURNKEY_PREFS")"; else live="$(turnkey_deb822_path "$name")"; fi
        [ -e "$live$KEEL_DISABLED_SUFFIX" ] || continue
        if [ -e "$live" ]; then
            printf 'conflict-tkfile\t%s\tboth names exist: rename one by hand\n' "$live"
        else
            printf 'restore-tkfile\t%s\tfrom %s%s, byte for byte\n' "$live" "${live##*/}" "$KEEL_DISABLED_SUFFIX"
        fi
    done
    prefs="$(turnkey_keys_saved)"
    if [ -f "$prefs" ]; then
        printf 'unpack-turnkeykeys\tturnkey-keys\tits files are back; reinstall the package with: apt-get update && apt-get install turnkey-keys\n'
    fi
    return 0
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
    plan_rollback_turnkey
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
            create-debian | update-debian | create-security | update-security)
                write_file "$path" "$(debian_render "${op#*-}")" || rc=$EXIT_WRITE_FAILED ;;
            disable-turnkey | disable-tkfile | disable-tkpin)
                mv "$path" "$path$KEEL_DISABLED_SUFFIX" || rc=$EXIT_WRITE_FAILED ;;
            restore-turnkey | restore-tkfile)
                mv "$path$KEEL_DISABLED_SUFFIX" "$path" || rc=$EXIT_ROLLBACK_INCOMPLETE ;;
            remove-sources | remove-pin | remove-debian | remove-security)
                rm -f "$path" || rc=$EXIT_WRITE_FAILED ;;
            purge-turnkeykeys)
                # never with a refusal or a failure before it in this run
                if [ "$rc" -eq 0 ]; then
                    turnkey_keys_purge || rc=$EXIT_WRITE_FAILED
                fi ;;
            unpack-turnkeykeys)
                turnkey_keys_restore || rc=$EXIT_ROLLBACK_INCOMPLETE ;;
            conflict-*) rc="$conflict_code" ;;
            *) : ;;
        esac
    done
    return "$rc"
}

