#!/usr/bin/env zsh
# test_update_phases.zsh — L2 tests for the update phase runners
# (_update_phase_pull / _update_phase_unpack / _update_phase_post): stub
# hooks registered via the real _update_register_hook record their
# invocations; tests assert ordering, skip logic, force override, the
# --phase passthrough, and failure semantics.
#
# No git involved — this layer is pure orchestration over the registry and
# the _dotfiler_plan_* globals.
setopt extendedglob

# update.zsh is source-guarded ([[ $ZSH_EVAL_CONTEXT == *:file* ]]) and
# sources helpers/update_core/setup_core itself.
source "${0:A:h}/../update.zsh"

typeset -i pass=0 fail=0
section() { printf '\n--- %s ---\n' "$1"; }

typeset -ga CALLS
typeset -gi _force=0
typeset -ga force=()  # referenced by sourced update code  # shuck: ignore=C001

# mk_stub <name> [pull-rc] [post-rc]
#   Define stub_<name>_{plan,pull,unpack,post} that append to CALLS.
mk_stub() {
    local _n=$1 _pull_rc=${2:-0} _post_rc=${3:-0}
    functions[stub_${_n}_plan]="CALLS+=(\"${_n}:plan:\${1:-}\")"
    functions[stub_${_n}_pull]="CALLS+=(\"${_n}:pull:\${1:-}\"); return ${_pull_rc}"
    functions[stub_${_n}_unpack]="CALLS+=(\"${_n}:unpack\")"
    functions[stub_${_n}_post]="CALLS+=(\"${_n}:post:\${1:-}\"); return ${_post_rc}"
}

# reg <name> — register a stub hook through the production API
reg() {
    _update_register_hook "$1" '' "stub_${1}_plan" "stub_${1}_pull" \
        "stub_${1}_unpack" "stub_${1}_post"
}

reset_registry() {
    _update_core_init_registry
    _dotfiler_registered_hooks=()
    _dotfiler_hook_check_fn=() _dotfiler_hook_plan_fn=()
    _dotfiler_hook_pull_fn=()  _dotfiler_hook_unpack_fn=()
    _dotfiler_hook_post_fn=()  _dotfiler_hook_cleanup_fn=()
    _dotfiler_hook_component_dir=() _dotfiler_hook_topology=()
    _dotfiler_hook_setup_fn=()
    CALLS=()
    _force=0
}

# plan_for <name> <range> [unpack-file ...]
plan_for() {
    local _n=$1 _r=$2; shift 2
    typeset -g  "_dotfiler_plan_${_n}_range"="$_r"
    typeset -ga "_dotfiler_plan_${_n}_to_unpack"
    typeset -ga "_dotfiler_plan_${_n}_to_remove"
    set -A "_dotfiler_plan_${_n}_to_unpack" "$@"
    set -A "_dotfiler_plan_${_n}_to_remove"
}

check_calls() {
    local _desc=$1 _expect=$2
    local _got="${(j: :)CALLS}"
    if [[ "$_got" == "$_expect" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      got:  %s\n      want: %s\n' "$_desc" "$_got" "$_expect"
        (( fail++ ))
    fi
}

check_rc() {
    local _desc=$1 _got=$2 _want=$3
    if [[ "$_got" == "$_want" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n      rc=%s want=%s\n' "$_desc" "$_got" "$_want"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
section "registration order drives phase order"
reset_registry
mk_stub main; mk_stub compA; mk_stub compB
reg main; reg compA; reg compB
plan_for main  "a..b" .f1
plan_for compA "c..d" .f2
plan_for compB "e..f" .f3

CALLS=(); _update_phase_pull --phase=components
check_calls "pull runs hooks in registration order with --phase" \
    "main:pull:--phase=components compA:pull:--phase=components compB:pull:--phase=components"

CALLS=(); _update_phase_unpack
check_calls "unpack runs hooks in registration order" \
    "main:unpack compA:unpack compB:unpack"

CALLS=(); _update_phase_post --phase=dotfiles
check_calls "post runs hooks in registration order with --phase" \
    "main:post:--phase=dotfiles compA:post:--phase=dotfiles compB:post:--phase=dotfiles"

# ---------------------------------------------------------------------------
section "skip logic"
reset_registry
mk_stub main; mk_stub compA; mk_stub compB
reg main; reg compA; reg compB
plan_for main  "a..b" .f1
plan_for compA "" # no range, nothing planned
plan_for compB "e..f" .f3

CALLS=(); _update_phase_pull --phase=components
check_calls "pull skips a component with no planned range; main always runs" \
    "main:pull:--phase=components compB:pull:--phase=components"

CALLS=(); _update_phase_unpack
check_calls "unpack skips a component with empty plans" \
    "main:unpack compB:unpack"

# post has no skip logic — stamps must always be maintained
CALLS=(); _update_phase_post --phase=components
check_calls "post never skips" \
    "main:post:--phase=components compA:post:--phase=components compB:post:--phase=components"

# force overrides both skips
_force=1
CALLS=(); _update_phase_pull --phase=components
check_calls "force pulls a rangeless component" \
    "main:pull:--phase=components compA:pull:--phase=components compB:pull:--phase=components"
CALLS=(); _update_phase_unpack
check_calls "force unpacks an empty-plan component" \
    "main:unpack compA:unpack compB:unpack"
_force=0

# ---------------------------------------------------------------------------
section "failure semantics"
reset_registry
mk_stub main; mk_stub compA 1; mk_stub compB    # compA pull fails
reg main; reg compA; reg compB
plan_for main  "a..b" .f1
plan_for compA "c..d" .f2
plan_for compB "e..f" .f3

CALLS=(); _update_phase_pull --phase=components; rc=$?
check_rc    "pull failure aborts the phase" $rc 1
check_calls "later hooks not pulled after a failure" \
    "main:pull:--phase=components compA:pull:--phase=components"

reset_registry
mk_stub main; mk_stub compA 0 1; mk_stub compB  # compA post fails
reg main; reg compA; reg compB
plan_for main  "a..b" .f1
plan_for compA "c..d" .f2
plan_for compB "e..f" .f3

CALLS=(); _update_phase_post --phase=components; rc=$?
check_rc    "post failure does not abort the phase" $rc 0
check_calls "post continues past a failing hook" \
    "main:post:--phase=components compA:post:--phase=components compB:post:--phase=components"

# unpack failure aborts (a failed link step must not be papered over)
reset_registry
mk_stub main; mk_stub compA; mk_stub compB
functions[stub_compA_unpack]='CALLS+=("compA:unpack"); return 1'
reg main; reg compA; reg compB
plan_for main  "a..b" .f1
plan_for compA "c..d" .f2
plan_for compB "e..f" .f3

CALLS=(); _update_phase_unpack; rc=$?
check_rc    "unpack failure aborts the phase" $rc 1
check_calls "later hooks not unpacked after a failure" \
    "main:unpack compA:unpack"

# ---------------------------------------------------------------------------
section "hooks without phase functions are tolerated"
reset_registry
mk_stub main
reg main
_update_register_hook bare '' '' '' '' ''   # registers with no fns at all
plan_for main "a..b" .f1

CALLS=(); _update_phase_pull --phase=components; rc=$?
check_rc    "pull tolerates a bare hook" $rc 0
CALLS=(); _update_phase_unpack; rc=$?
check_rc    "unpack tolerates a bare hook" $rc 0
CALLS=(); _update_phase_post --phase=components; rc=$?
check_rc    "post tolerates a bare hook" $rc 0

printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
