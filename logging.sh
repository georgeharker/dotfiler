#!/bin/zsh

# Global quiet mode setting - defaults to not quiet
quiet_mode=false
verbose_mode=false

function cleanup_logging(){
    # Unset variables
    unset quiet_mode 2>/dev/null
    unset verbose_mode 2>/dev/null
    
    # Unset all functions defined in this file
    unset -f cleanup_logging 2>/dev/null
    unset -f info 2>/dev/null
    unset -f info_nonnl 2>/dev/null
    unset -f success 2>/dev/null
    unset -f report 2>/dev/null
    unset -f action 2>/dev/null
    unset -f error 2>/dev/null
    unset -f warn 2>/dev/null
}

# Helper output functions that respect quiet_mode
function verbose(){
    [[ "$verbose_mode" = true ]] || print -P "$@"
}

function info(){
    [[ "$quiet_mode" = true ]] || print -P "$@"
}

function info_nonl(){
    [[ "$quiet_mode" = true ]] || print -n -P "$@"
}

function success(){
    [[ "$quiet_mode" = true ]] || print -P "%F{green}$@%f"
}

function report(){
    [[ "$quiet_mode" = true ]] || print -P "%F{cyan}$@%f"
}

function action(){
    [[ "$quiet_mode" = true ]] || print -P "%F{blue}$@%f"
}

function error(){
    [[ "$quiet_mode" = true ]] || print -P "%F{red}$@%f"
}

function warn(){
    [[ "$quiet_mode" = true ]] || print -P "%F{yellow}$@%f"
}
