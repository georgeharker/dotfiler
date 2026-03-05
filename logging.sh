#!/bin/zsh

# Global quiet mode setting - defaults to not quiet
quiet_mode=false
verbose_mode=false

function cleanup_logging() {
	unset quiet_mode 2>/dev/null
	unset verbose_mode 2>/dev/null
	unset -f cleanup_logging info info_nonl success report action error warn \
		verbose 2>/dev/null
}

# Helper output functions.
# info/verbose/success/report/action → stdout (user-facing progress, pipeable)
# warn/error → stderr (diagnostics, never suppress)

function verbose() {
	{ [[ "$verbose_mode" = true ]] || [[ -n "${DOTFILES_DEBUG:-}" ]]; } &&
		print -P "%F{cyan}[debug]%f $@"
	return 0
}

function info() {
	[[ "$quiet_mode" = true ]] || print -P "$@"
	return 0
}

function info_nonl() {
	[[ "$quiet_mode" = true ]] || print -n -P "$@"
	return 0
}

function success() {
	[[ "$quiet_mode" = true ]] || print -P "%F{green}$@%f"
	return 0
}

function report() {
	[[ "$quiet_mode" = true ]] || print -P "%F{cyan}$@%f"
	return 0
}

function action() {
	[[ "$quiet_mode" = true ]] || print -P "%F{blue}$@%f"
	return 0
}

function error() {
	print -P "%F{red}$@%f" >&2
	return 0
}

function warn() {
	print -P "%F{yellow}$@%f" >&2
	return 0
}
