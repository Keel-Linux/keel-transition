#!/bin/bash
# shellcheck shell=bash
# keel-transition: the whole library, in load order. bin/keel-transition
# sources this one file and calls transition_main; everything else is here
# so that each part stays small and separately testable (decision 0004).
#
# Nothing in this library installs, upgrades or removes a package. The tool
# changes apt sources, one preferences file and the instance spec.
#
# Every path is read through rooted(), so the whole library runs against a
# scratch tree by setting KEEL_ROOT, which is how the bats suite reaches
# every branch without touching the live system.

keel_transition_lib_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

. "$keel_transition_lib_dir/common.sh"
. "$keel_transition_lib_dir/archive.sh"
. "$keel_transition_lib_dir/plan.sh"
. "$keel_transition_lib_dir/phases.sh"
