#!/usr/bin/env zsh
# setup_core.zsh — dotfiler setup core library, safe to source from any context.
#
# Pure library: no multi-component awareness, no exec guard.
# Sourced by:
#   - setup.zsh   (the CLI entry point / multi-component orchestrator)
#   - update.zsh  (in a subshell, for the unpack phase)
#   - zdot's update-impl.zsh (in a subshell, for zdot's unpack phase)
#
# Provides:
#   Gitignore/exclusion system:
#     read_exclusion_patterns, build_find_prune_args,
#     _gitignore_match_single, should_exclude_file
#   Filesystem helpers:
#     normalize_path_to_dest_relative, prompt_yes_no,
#     safe_mkdir, safe_ln, safe_rm, safe_cp, safe_cp_r, safe_git,
#     dolink, link_if_needed, copy_in_if_needed, untrack_if_needed
#   Find helpers (self-contained, take start_dir + exclude_file):
#     setup_find_shallow  — top-level dot-entries only
#     setup_find_deep     — all files/symlinks with prune
#     setup_find          — both combined (no depth restriction)
#   Entry points (called by setup.zsh or update.zsh):
#     setup_run_unpack        — unpack specific files (respecting exclusions)
#     setup_run_force_unpack  — unpack specific files (ignoring exclusions)
#     setup_run_all           — full action dispatch (setup/track/untrack/unpack/force)
#     setup_core_main         — single-repo CLI parser + dispatch
#   Cleanup:
#     setup_core_unload   — undefine all functions and globals set by this lib
#
# Globals set by _setup_init (used by all other functions):
#   dotfiles_dir, _setup_link_dest, dry_run, quiet, defyes, defno,
#   findopt, findoptd, find_prune_args,
#   _gitignore_rules, _prune_dir_names



# When exec'd directly (not sourced into an environment that already loaded
# helpers.zsh), pull in the helpers so find_dotfiles_directory etc. are defined.
if (( ! ${+functions[find_dotfiles_directory]} )); then
    source "${${(%):-%x}:A:h}/helpers.zsh"
fi

# ---------------------------------------------------------------------------
# Exclusion system — gitignore-style semantics
#
# Global state:
#   _gitignore_rules  — array of "FLAG:PATTERN" entries, in order.
#                       FLAG is either "enforce" (baked-in, immune to negation)
#                       or "user" (from a file, may be negated).
#   _prune_dir_names  — plain dir names to prune during find traversal
#                       (performance only; should_exclude_file is authoritative)
# ---------------------------------------------------------------------------

# _gitignore_rules and _prune_dir_names are module-level globals.
_gitignore_rules=()
_prune_dir_names=()

# read_exclusion_patterns [--enforce] [file]
#
#   Accumulates patterns from a file (or baked-in defaults) into
#   _gitignore_rules.  May be called multiple times.
#
#   --enforce  patterns from this call cannot be overridden by user negation
#
#   If no file is given (or the file does not exist) and --enforce is set,
#   the baked-in minimal ruleset is loaded instead.
read_exclusion_patterns() {
    local enforce=0
    [[ "${1:-}" == "--enforce" ]] && { enforce=1; shift; }
    local exclusion_file="${1:-}"
    local flag="user"
    (( enforce )) && flag="enforce"
    
    if [[ -z "$exclusion_file" ]] || [[ ! -f "$exclusion_file" ]]; then
        if (( enforce )); then
            # Minimal baked-in rules — only things that break dotfiler if linked.
            # These are stored as enforce rules so user negation cannot un-exclude them.
            _gitignore_rules+=("${flag}:.git/" "${flag}:.nounpack/")
            _prune_dir_names+=(".git" ".nounpack")
        fi
        return 0
    fi

    # Read file line-by-line; (f) splits on newlines, (@) preserves array form.
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Strip inline comments (not standard gitignore but harmless)
        # Skip blank lines and comment-only lines
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        _gitignore_rules+=("${flag}:${line}")

        # Collect plain directory names for find -prune (performance).
        # Only add if: no path separator, no glob chars, and either has a
        # trailing / (explicit dir marker) or starts with a dot and has no
        # extension (e.g. .git, .venv) or is a plain word with no extension.
        local bare="${line#!}"      # strip possible leading !
        local has_trailing_slash=0
        [[ "$bare" == */ ]] && has_trailing_slash=1
        bare="${bare%/}"            # strip trailing /
        if [[ "$bare" != */* ]] && [[ "$bare" != "/"* ]] && [[ "$bare" != *[\*\?\[]* ]]; then
            if (( has_trailing_slash )) || [[ "$bare" != *.* ]]; then
                _prune_dir_names+=("$bare")
            fi
        fi
    done < "$exclusion_file"
}

# exclude_component_dirs
#
#   Reads the hook registry and adds each component's graft point as an
#   enforce-level exclusion so the dotfiles unpack never installs files that
#   belong to a component.  Only applies to non-subdir topologies (submodule,
#   subtree, standalone) — subdir components live inside dotfiles and are
#   managed as normal dotfiles.
#
#   Must be called after _setup_discover_hooks has populated the registry
#   and before setup_core_main processes files.
exclude_component_dirs() {
    local _dotfiles_dir="${1:A}"
    local _name _comp_dir _topology _rel

    for _name in "${_dotfiler_registered_hooks[@]}"; do
        _comp_dir="${_dotfiler_hook_component_dir[$_name]:-}"
        _topology="${_dotfiler_hook_topology[$_name]:-}"

        [[ -z "$_comp_dir" || "$_topology" == subdir ]] && continue

        # Make relative to dotfiles root for pattern matching
        _rel="${_comp_dir#${_dotfiles_dir}/}"
        # Skip if it didn't strip (component outside dotfiles tree)
        [[ "$_rel" == "$_comp_dir" ]] && continue

        log_debug "setup: auto-excluding component graft point: $_rel (topology: $_topology)"
        _gitignore_rules+=("enforce:/${_rel}/")
        _prune_dir_names+=("${_rel##*/}")
    done
}


#
#   Builds the global `find_prune_args` array used to prune excluded
#   directories during traversal for performance.  This is NOT authoritative;
#   should_exclude_file() is the single source of truth.
#
#   Result: find_prune_args — expression of the form:
#     -type d ( -name A -or -name B ... ) -prune
#   suitable for use as: \( "${find_prune_args[@]}" \) -o \( ... -print \)
build_find_prune_args() {
    local -a unique_names=("${(@u)_prune_dir_names}")
    local -a name_expr=()

    for name in "${unique_names[@]}"; do
        [[ -z "$name" ]] && continue
        if [[ ${#name_expr[@]} -gt 0 ]]; then
            name_expr+=("-or")
        fi
        name_expr+=("-name" "$name")
    done

    if [[ ${#name_expr[@]} -gt 0 ]]; then
        find_prune_args=("-type" "d" "(" "${name_expr[@]}" ")" "-prune")
    else
        find_prune_args=()
    fi
}

# _gitignore_match_single PATTERN RELATIVE_PATH IS_DIR
#
#   Tests one gitignore pattern against a dotfiles-relative path.
#   Returns 0 (exclude) or 1 (keep).  Does not handle negation.
#   See gitignore_match.zsh for full semantics documentation.

_gitignore_match_single() {
    local pattern="$1"
    local rel_path="$2"
    local is_dir="${3:-0}"

    # Guard: empty pattern or bare / matches nothing.
    [[ -z "$pattern" || "$pattern" == "/" ]] && return 1

    setopt local_options extendedglob

    # --- strip trailing / → dir_only ---
    local dir_only=0
    local pat="$pattern"
    if [[ "$pat" == */ ]]; then
        dir_only=1
        pat="${pat%/}"
    fi

    # --- determine anchoring ---
    local anchored=0
    if [[ "$pat" == /* ]]; then
        anchored=1
        pat="${pat#/}"
    elif [[ "$pat" == */* ]]; then
        anchored=1
    fi

    # Does the pattern contain glob chars?
    local has_glob=0
    [[ "$pat" == *'*'* || "$pat" == *'?'* || "$pat" == *'['* ]] && has_glob=1

    # Glob-safe version for ${~...} expansion.
    # In zsh extendedglob, # is a quantifier — escape it so patterns like
    # "#*#" match the literal character # rather than triggering a syntax error.
    local gpat="${pat//'#'/\#}"

    # -----------------------------------------------------------------------
    # FP1 — UNANCHORED  (no / in pattern after stripping trailing /)
    #   Examples: .mypy_cache  *.swp  .DS_Store  node_modules
    # -----------------------------------------------------------------------
    if (( ! anchored )); then
        if (( dir_only )); then
            if (( has_glob )); then
                # Glob: test each path component individually.
                local _c _r="$rel_path"
                while true; do
                    _c="${_r%%/*}"
                    [[ "$_c" == ${~gpat} ]] && return 0
                    [[ "$_r" == "$_c" ]] && break
                    _r="${_r#*/}"
                done
            else
                # Literal dir: the component must appear with a path element
                # AFTER it (i.e. rel_path has something under the dir).
                # "/${path}/" =~ *"/pat/"?*  ensures content follows.
                [[ "/${rel_path}/" == *"/${pat}/"?* ]] && return 0
                # Also catch the dir itself when caller signals is_dir=1.
                (( is_dir )) && [[ "${rel_path:t}" == "$pat" ]] && return 0
            fi
        else
            # Match the basename.
            [[ "${rel_path:t}" == ${~gpat} ]] && return 0
            # For literal patterns, also match files inside a same-named dir
            # (e.g. bare ".mypy_cache" excludes .mypy_cache/foo.py).
            if (( ! has_glob )); then
                [[ "/${rel_path}/" == *"/${pat}/"?* ]] && return 0
            fi
        fi
        return 1
    fi

    # -----------------------------------------------------------------------
    # FP2 — ANCHORED, NO WILDCARDS
    #   Examples: /.nounpack  .config/karabiner  /dotfiles_exclude
    # -----------------------------------------------------------------------
    if (( ! has_glob )); then
        [[ "$rel_path" == "$pat" || "$rel_path" == "$pat/"* ]] && return 0
        return 1
    fi

    # -----------------------------------------------------------------------
    # FP3 — ANCHORED, CONTAINS **
    #   Examples: .codecompanion/**  foo/**/bar  **/foo
    #
    #   zsh ** in [[ == ]] crosses / but requires 1+ chars per ** segment.
    #   We handle the zero-segment cases explicitly:
    #
    #   A: **/rest  → rest anchored at root (zero-prefix case)
    #   B: prefix/** → everything strictly under prefix/ (not prefix itself)
    #   C: a/**/b   → a/b  (zero middle segments, collapse /**/ → /)
    # -----------------------------------------------------------------------
    if [[ "$pat" == *'**'* ]]; then
        # Primary zsh match (handles 1+ segments for **).
        [[ "$rel_path" == ${~gpat} ]] && return 0
        # Also match contents of a directory the pattern resolves to.
        # Exception: trailing /** means contents only, not the dir itself,
        # so we only add /* when the ** is NOT at the very end.
        if [[ "$pat" != *'/**' ]]; then
            [[ "$rel_path" == ${~gpat}/* ]] && return 0
        fi

        # Sub-case A: **/rest — rest matches at root (zero path prefix).
        if [[ "$pat" == '**/'* ]]; then
            local _rest="${pat#'**/'}"
            local _gr="${_rest//'#'/\#}"
            # Exact match at root.
            [[ "$rel_path" == ${~_gr} ]] && return 0
            # Contents under a literal dir named _rest at root.
            [[ "$rel_path" == */${~_gr} ]] && return 0
        fi

        # Sub-case B: prefix/** — contents only (not the prefix dir itself).
        if [[ "$pat" == *'/**' ]]; then
            local _pfx="${pat%'/**'}"
            local _gp="${_pfx//'#'/\#}"
            [[ "$rel_path" == ${~_gp}/* ]] && return 0
        fi

        # Sub-case C: a/**/b — collapse /**/ → / for zero-middle-segments.
        # This handles only the EXACT zero-match case (a/b from a/**/b).
        # The /* suffix is intentionally absent — a/**/b does not match
        # a/b/extra (b is the final component, not a directory).
        if [[ "$pat" == *'/**/'* ]]; then
            local _col="$pat" _prev="" _sl="/"
            while [[ "$_col" != "$_prev" ]]; do
                _prev="$_col"
                _col="${_col/\/**\//$_sl}"
            done
            if [[ "$_col" != "$pat" ]]; then
                local _gc="${_col//'#'/\#}"
                [[ "$rel_path" == ${~_gc} ]] && return 0
            fi
        fi

        return 1
    fi

    # -----------------------------------------------------------------------
    # FP4 — ANCHORED, * or ? but NOT **  (iterative segment walk)
    #   Examples: .codecompanion/*  src/?.c  build/*/output
    #
    #   In zsh [[ == ]], * crosses / — wrong for gitignore.
    #   Walk segments with ${%%/*} / ${#*/}: each [[ seg == pat_seg ]] call
    #   matches within one segment so * cannot cross a slash.
    # -----------------------------------------------------------------------
    local pat_rest="$pat" path_rest="$rel_path"

    while true; do
        local pat_seg="${pat_rest%%/*}"
        local path_seg="${path_rest%%/*}"
        local gpat_seg="${pat_seg//'#'/\#}"

        [[ "$path_seg" == ${~gpat_seg} ]] || return 1

        local pat_next="${pat_rest#*/}"
        local path_next="${path_rest#*/}"

        if [[ "$pat_next" == "$pat_rest" ]]; then
            # Pattern exhausted.
            [[ "$path_next" == "$path_rest" ]] && return 0   # exact match
            # Path has more — include contents if dir_only or literal final seg.
            local seg_is_glob=0
            [[ "$pat_seg" == *'*'* || "$pat_seg" == *'?'* || "$pat_seg" == *'['* ]] \
                && seg_is_glob=1
            (( dir_only || ! seg_is_glob )) && return 0
            return 1
        fi

        [[ "$path_next" == "$path_rest" ]] && return 1

        pat_rest="$pat_next"
        path_rest="$path_next"
    done
}

# should_exclude_file PATH [is_dir]
#
#   Canonical exclusion predicate.  Applies all accumulated rules in order,
#   with later rules overriding earlier ones (gitignore semantics).
#   Enforce rules are immune to user negation.
#
#   Returns 0 = exclude, 1 = keep.
function should_exclude_file() {
    local file_path="$1"
    local is_dir="${2:-0}"
    local abs_file_path="${file_path:A}"
    local dotfiles_dir_abs="${dotfiles_dir:A}"

    # Compute path relative to dotfiles root.
    local relative_path=""
    if [[ "$abs_file_path" == "$dotfiles_dir_abs/"* ]]; then
        relative_path="${abs_file_path#$dotfiles_dir_abs/}"
    else
        # Path outside dotfiles dir — cannot match
        return 1
    fi

    # Walk rules in order; track current verdict and whether the current
    # exclusion came from an enforce rule.
    local verdict=1          # 1 = keep (default)
    local verdict_enforced=0 # 1 if current verdict came from an enforce rule

    local rule flag pattern negated
    for rule in "${_gitignore_rules[@]}"; do
        flag="${rule%%:*}"
        pattern="${rule#*:}"
        negated=0

        if [[ "$pattern" == !* ]]; then
            negated=1
            pattern="${pattern#!}"
        fi

        if (( negated )); then
            # Negation: if this pattern matches, override exclusion — but only
            # if the current exclusion was NOT from an enforce rule.
            if [[ "$flag" == "enforce" ]]; then
                # Enforce negation re-includes even enforced exclusions.
                # (Unlikely to be used, but consistent.)
                _gitignore_match_single "$pattern" "$relative_path" "$is_dir" && \
                    { verdict=1; verdict_enforced=0; }
            else
                # User negation cannot override an enforce exclusion.
                if (( ! verdict_enforced )) || [[ "$verdict" == "1" ]]; then
                    _gitignore_match_single "$pattern" "$relative_path" "$is_dir" && \
                        { verdict=1; verdict_enforced=0; }
                fi
            fi
        else
            _gitignore_match_single "$pattern" "$relative_path" "$is_dir" && {
                verdict=0
                [[ "$flag" == "enforce" ]] && verdict_enforced=1 || verdict_enforced=0
            }
        fi
    done

    return $verdict
}

# ---------------------------------------------------------------------------
# Filesystem helpers
# ---------------------------------------------------------------------------

function normalize_path_to_dest_relative(){
  local input_path="$1"
  local force_dest_rel="${2:-0}"
  local fullpath_dest="${_setup_link_dest:A}"
  local abs_path

  # Skip empty paths
  [[ -z "$input_path" ]] && return 1

  # NOTE: we must take care not to resolve symlinks that would point
  # back at dotfiles

  # Convert to absolute path
  if [[ "$input_path" == /* ]]; then
    # Already absolute
    abs_path="${input_path:a}"
  else
    if [ $force_dest_rel -eq 1 ]; then
      # Force relative to dest directory
      abs_path="${fullpath_dest}/${input_path}"
      abs_path="${abs_path:a}"
    else
      # Relative path - resolve relative to CWD
      # Check if file exists relative to CWD
      if [[ -e "$input_path" ]]; then
        abs_path="${input_path:a}"
      else
        # File doesn't exist yet, but we still need to normalize the path
        # Resolve it relative to CWD
        abs_path="${PWD:A}/${input_path}"
        # Normalize the path (resolve .. and . components)
        abs_path="${abs_path:a}"
      fi
    fi
  fi

  # Check if path is under dest directory
  if [[ "$abs_path" == "$fullpath_dest/"* ]]; then
    # Return relative path from dest (without leading /)
    local rel_path="${abs_path#$fullpath_dest/}"
    print -r -- "$rel_path"
    return 0
  else
    # Path is not under dest directory
    warn "Path $input_path (resolves to $abs_path) is not under dest directory ($fullpath_dest)" > /dev/stderr
    return 1
  fi
}

function prompt_yes_no(){
  [[ ${#dry_run[@]} -ge 1 ]] && return 1
    [[ ${#defno[@]} -ge 1 ]] && return 1
    [[ ${#defyes[@]} -ge 1 ]] && return 0
  if read -qs "REPLY?$1? (N/y)"; then
        >&2 echo $REPLY
        return 0
  fi
    >&2 echo $REPLY
    return 1
}

# Safe filesystem operation wrappers that respect dry run mode
function safe_mkdir(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would create directory: $1"
    else
        mkdir -p "$1"
    fi
}

function safe_ln(){
    local src="$1"
    local dest="$2"
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would create symlink: $dest -> $src"
    else
        ln -s "$src" "$dest"
    fi
}

function safe_rm(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would remove: $1"
    else
        rm "$1"
    fi
}

function safe_cp(){
    local src="$1"
    local dest="$2"
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would copy: $src -> $dest"
    else
        cp "$src" "$dest"
    fi
}

function safe_cp_r(){
    local src="$1"
    local dest="$2"
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would copy recursively: $src -> $dest"
    else
        cp -r "$src" "$dest"
    fi
}

function safe_git(){
    if [[ ${#dry_run[@]} -gt 0 ]]; then
        action "[DRY RUN] Would run git: git $*"
    else
        git "$@"
    fi
}

function dolink(){
  src=$1
  dest=$2
  destdir="${dest:h}"
  safe_mkdir $destdir
  safe_ln $src $destdir/
  action ".. Linked $src to $dest"
}

function link_if_needed(){
  src=$1:a
  fullpath_dotfiles_dir=$dotfiles_dir:A
  dest="${_setup_link_dest}/"${1#$fullpath_dotfiles_dir/}
  log_debug "link_if_needed src=$src dest=$dest"
  info_nonl "checking $src to $dest .."
  if [[ -L "$dest" ]]; then
    linkfile=$(readlink $dest)
    if [[ "$src" != "$linkfile" ]]; then
      error ".. Failed to link $src to $dest, conflicting link ($linkfile)"
    else
      info ".. ok"
    fi
  elif [[ -f "$dest" ]] && [[ -f "$src" ]]; then
    info ".. $dest exists checking contents for diffs"
    # check if the contents are the same
    diffs="${(f@)$(diff "$src" "$dest")}"
    if [[ ${#diffs[@]} -gt 0 ]]; then
      warn "Diffs (${#diffs[@]}):"
      for each ("$diffs[@]")
      do
        warn "${each}"
      done
      msg=".. file $dest exists and is DIFFERENT, replace with link?"
    else
      msg=".. file $dest exists and is identical, replace with link?"
    fi
    if prompt_yes_no "$msg"; then
      safe_rm $dest
      dolink $src $dest
    else
      warn ".. Refused link of $src to $dest"
            return 0
    fi
  elif [[ -e "$dest" ]] && [[ -f "$src" ]]; then
    error ".. Refused link of $src to $dest, something in the way"
        return 1
  elif [[ -d "$src" ]]; then
      if [[ -d "$dest" ]] || [[ ! -e "$dest" ]]; then
        info ".. skipping directory $dest"
      elif [[ -e "$dest" ]]; then
        error ".. Failed dest directory $dest exists as non directory"
            return 1
      fi
  else
    dolink $src $dest
  fi
}

function copy_in_if_needed(){
  # Input is now expected to be a path relative to _setup_link_dest (already normalized)
  local home_relative_path="$1"
  local fullpath_home="${_setup_link_dest:A}"
  local fullpath_dotfiles_dir="${dotfiles_dir:A}"

  # Construct absolute source path from dest-relative path
  src="${fullpath_home}/${home_relative_path}"
  src="${src:A}"

  # SAFETY CHECK: Prevent re-ingesting symlinked files
  if [[ -L "$src" ]]; then
    link_target=$(readlink "$src")
    link_target_abs="${link_target:A}"
    if [[ "$link_target_abs" == "$fullpath_dotfiles_dir"* ]]; then
      info ".. SKIPPING: $src is already a symlink to dotfiles ($link_target_abs)"
      return 0
    fi
  fi

  # Check if source is already in dotfiles directory
  if [[ "$src" == "$fullpath_dotfiles_dir"* ]]; then
    # Source is already in dotfiles, so we're probably re-ingesting from dotfiles to dotfiles
    # This shouldn't happen in normal usage, but let's handle it gracefully
    info ".. WARNING: Source $src is already in dotfiles directory"
    return 0
  fi

  # Use the home-relative path to construct destination in dotfiles
  dest="${dotfiles_dir}/${home_relative_path}"
  if [ ! -d "$src" ]; then
      destdir="${dest:h}"
  else
      destdir="${dest}"
  fi
  
  info_nonl "checking $src to $dest ($destdir) .."
  if [[ -e "$dest" ]]; then
    info ".. $dest exists"
    # Oops it exists
    if [[ -f "$src" ]]; then
      info ".. checking contents for diffs"
      # check if the contents are the same
      diffs=$(diff "$src" "$dest")
      if [[ "$diffs" == "" ]]; then
        info ".. ok"
      else
        warn ".. File $dest exists and differs from $src"
        msg="Update tracked file $dest with contents from $src?"
        if prompt_yes_no "$msg"; then
          safe_cp "$src" "$dest"
          action ".. Updated $dest with contents from $src"
        else
          warn ".. Skipped updating $dest"
        fi
      fi
    elif [[ -d "$src" ]]; then
      info ".. checking directory contents for diffs"
      # Check if directory contents are the same
      diffs=$(diff "$src" "$dest")
      if [[ "$diffs" == "" ]]; then
        info ".. ok"
      else
        warn ".. Directory $dest exists and differs from $src"
        msg="Update tracked directory $dest with contents from $src?"
        if prompt_yes_no "$msg"; then
          safe_cp_r "$src"/* "$dest"/
          action ".. Updated $dest with contents from $src"
        else
          warn ".. Skipped updating $dest"
        fi
      fi
    else
      error ".. Can't deal with special file $src"
    fi
  else
    msg="Track $src"
    if prompt_yes_no "$msg"; then
      safe_mkdir $destdir
      safe_cp_r $src $destdir
      action ".. Copied $src to $dest"
      safe_git -C "$dotfiles_dir" add "$dest"
    fi
  fi
  return 0
}

function untrack_if_needed(){
  # Input is now expected to be a path relative to HOME (already normalized)
  local home_relative_path="$1"
  local fullpath_dotfiles_dir="${dotfiles_dir:A}"

  # Construct paths from dest-relative path
  src="${dotfiles_dir}/${home_relative_path}"
  src="${src:A}"
  home_path="${_setup_link_dest}/${home_relative_path}"
  home_path="${home_path:A}"
  
  info_nonl "untracking $src (home: $home_path) .."
  
  if [[ -f "$src" ]]; then
    # Remove symlink from home if it exists and points to this file
    if [[ -L "$home_path" ]]; then
      link_target=$(readlink "$home_path")
      if [[ "$link_target" == "$src" ]]; then
        safe_rm "$home_path"
        action ".. Removed symlink $home_path"
      else
        warn ".. Symlink $home_path points to different target: $link_target"
      fi
    elif [[ -f "$home_path" ]]; then
      warn ".. $home_path exists but is not a symlink"
    fi
    
    # Remove from git and filesystem
    safe_git -C "$dotfiles_dir" rm "$home_relative_path"
    action ".. Removed $src from git tracking"
  elif [[ -d "$src" ]]; then
    # Handle directory removal
    safe_git -C "$dotfiles_dir" rm -r "$home_relative_path"
    action ".. Removed directory $src from git tracking"
  else
    error ".. File $src does not exist"
        return 1
  fi
}

# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------

# setup_init <dotfiles_dir_override> <link_dest> <dry_run_bool> <quiet_bool>
#
#   Sets all globals needed by the other functions.
#   dotfiles_dir_override: explicit repo path, or "" to auto-detect.
#   link_dest: where symlinks are planted, or "" for $HOME.
#   dry_run_bool: 1 to enable dry-run mode, 0 for normal.
#   quiet_bool: 1 to suppress non-error output, 0 for normal.
# _setup_init dir_override link_dest dry_run_bool quiet_bool [defyes_bool [defno_bool]]
#   Internal: sets all globals needed by setup functions.
#   Called by each public entry point; not intended for external use.
function _setup_init() {
    local dir_override="$1"
    local link_dest_arg="$2"
    local dry_run_bool="${3:-0}"
    local quiet_bool="${4:-0}"
    local defyes_bool="${5:-0}"
    local defno_bool="${6:-0}"

    dry_run=()
    quiet=()
    defyes=()
    defno=()
    (( dry_run_bool )) && dry_run=("-D")
    (( quiet_bool ))   && quiet=("-q")
    (( defyes_bool ))  && defyes=("-y")
    (( defno_bool ))   && defno=("-n")

    if [[ -n "$dir_override" ]]; then
        dotfiles_dir="$dir_override"
    else
        dotfiles_dir=$(find_dotfiles_directory)
    fi

    _setup_link_dest="${link_dest_arg:-$HOME}"

    findopt=()
    findoptd=()
    if [[ $(uname) == "Darwin" ]]; then
        findoptd+=("-s")
    fi

    _gitignore_rules=()
    _prune_dir_names=()

    # Layer 1: enforce (.git/ .nounpack/ etc.)
    read_exclusion_patterns --enforce

    # Layer 1b: auto-exclude registered component graft points (enforce level).
    # Components manage their own files via their hook; the dotfiles unpack
    # must never install into their directory.
    exclude_component_dirs "$dotfiles_dir"

    # Layer 2: always_exclude — glob patterns applied to every repo.
    # Sought in dotfiles root first, fallback to dotfiler's own dir.
    local _dotfiles_root _always_exclude
    _dotfiles_root=$(find_dotfiles_directory 2>/dev/null || true)
    _always_exclude="${_dotfiles_root}/always_exclude"
    [[ -f "$_always_exclude" ]] || \
        _always_exclude="${${(%):-%x}:A:h}/always_exclude"
    [[ -f "$_always_exclude" ]] && read_exclusion_patterns "$_always_exclude"

    # Layer 3: caller-specified excludes (--excludes), OR dotfiles_exclude default.
    if [[ ${#_setup_excludes_files[@]} -gt 0 ]]; then
        local _ef
        for _ef in "${_setup_excludes_files[@]}"; do
            [[ -f "$_ef" ]] && read_exclusion_patterns "$_ef"
        done
    else
    local dotfiles_exclude_file
    dotfiles_exclude_file=$(find_dotfiles_exclude_file)
    read_exclusion_patterns "$dotfiles_exclude_file"
    fi

    build_find_prune_args

    if [[ -n "${DOTFILER_DEBUG:-}" ]]; then
        log_debug "setup: exclusion rules (${#_gitignore_rules[@]} total):"
        local _rule
        for _rule in "${_gitignore_rules[@]}"; do
            log_debug "  $_rule"
        done
        log_debug "setup: prune dir names: ${_prune_dir_names[*]}"
    fi

    (( dry_run_bool )) && warn "=== DRY RUN MODE ==="
}

# _setup_save_exclusion_state
#   Save the current exclusion rules and prune dir names into function-local
#   arrays _saved_rules and _saved_prune, then reset and reload for a
#   self-contained find operation.  Caller must declare:
#     local -a _saved_rules _saved_prune
#   before calling, and pass the exclude_file to reload from.
_setup_save_exclusion_state() {
    local exclude_file="$1"
    _saved_rules=("${_gitignore_rules[@]}")
    _saved_prune=("${_prune_dir_names[@]}")
    _gitignore_rules=()
    _prune_dir_names=()
    read_exclusion_patterns --enforce
    [[ -n "$exclude_file" ]] && read_exclusion_patterns "$exclude_file"
    return 0
}

# _setup_restore_exclusion_state
#   Restore exclusion rules and prune dir names saved by _setup_save_exclusion_state.
_setup_restore_exclusion_state() {
    _gitignore_rules=("${_saved_rules[@]}")
    _prune_dir_names=("${_saved_prune[@]}")
    return 0
}

# setup_find_shallow start_dir exclude_file
#
#   Print all top-level dot-entries (mindepth 1 maxdepth 1, name .[a-zA-Z]*)
#   under start_dir, filtered by exclusions from exclude_file.
#   Self-contained: loads its own exclusion rules.
function setup_find_shallow() {
    local start_dir="$1"
    local exclude_file="$2"

    local -a _fopt=() _foptd=()
    [[ "$(uname)" == "Darwin" ]] && _foptd+=("-s")

    local -a _saved_rules _saved_prune
    _setup_save_exclusion_state "$exclude_file"

    local find_output
    find_output=$(find $_foptd "$start_dir" $_fopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*")
    local f
    for f in ${(f)find_output}; do
        [[ -n "$f" ]] || continue
        should_exclude_file "$f" 0 && continue
        print -- "$f"
    done

    _setup_restore_exclusion_state
}

# setup_find_deep start_dir exclude_file
#
#   Print all files and symlinks (mindepth 1) under start_dir, pruning
#   directories matched by exclusions from exclude_file, and filtering
#   results through should_exclude_file.
#   Self-contained: loads its own exclusion rules.
function setup_find_deep() {
    local start_dir="$1"
    local exclude_file="$2"

    local -a _fopt=() _foptd=()
    [[ "$(uname)" == "Darwin" ]] && _foptd+=("-s")

    local -a _saved_rules _saved_prune
    _setup_save_exclusion_state "$exclude_file"

    local -a _local_prune=()
    build_find_prune_args   # populates find_prune_args

    local find_output
    if [[ ${#find_prune_args[@]} -gt 0 ]]; then
        find_output=$(find $_foptd "$start_dir" -mindepth 1 $_fopt \
            \( "${find_prune_args[@]}" \) -o \
            \( -type f -o -type l \) -print )
    else
        find_output=$(find $_foptd "$start_dir" -mindepth 1 $_fopt \
            \( -type f -o -type l \) )
    fi
    local f
    for f in ${(f)find_output}; do
        [[ -n "$f" ]] || continue
        should_exclude_file "$f" 0 && continue
        print -- "$f"
    done

    _setup_restore_exclusion_state
}

# setup_run_unpack dir_override link_dest dry_run_bool quiet_bool [file ...]
#
#   Unpack specific files from dotfiles_dir into _setup_link_dest,
#   respecting exclusions.  If no files given, unpacks everything.
function setup_run_unpack() {
    _setup_init "$1" "$2" "$3" "$4" 0 0
    shift 4
    # Normalize paths before passing to inner loop
    local -a normalized=() p n
    for p in "$@"; do
        n=$(normalize_path_to_dest_relative "$p" 1) || {
            error "Failed to normalize unpack path: $p"
            return 1
        }
        normalized+=("$n")
    done
    _setup_do_unpack "${normalized[@]}"
}

# setup_run_force_unpack dir_override link_dest dry_run_bool quiet_bool [file ...]
#
#   Like setup_run_unpack but ignores exclusions.
function setup_run_force_unpack() {
    _setup_init "$1" "$2" "$3" "$4" 0 0
    shift 4
    # Normalize paths before passing to inner loop
    local -a normalized=() p n
    for p in "$@"; do
        n=$(normalize_path_to_dest_relative "$p" 1) || {
            error "Failed to normalize force_unpack path: $p"
            return 1
        }
        normalized+=("$n")
    done
    _setup_do_unpack --force "${normalized[@]}"
}

# _setup_do_unpack [--force] [file ...]
#   Inner unpack loop. Requires globals from _setup_init.
#   --force: skip exclusion checks and use stricter error handling for missing files.
function _setup_do_unpack() {
    local _force=0
    [[ "${1:-}" == "--force" ]] && { _force=1; shift; }
    local -a _unpack_files=("$@")
    local _label="Linking" _label_all="Linking all files"
    (( _force )) && { _label="Force linking"; _label_all="Force linking all files (ignoring exclusions)"; }

    # Check if specific files were provided
    if [[ ${#_unpack_files[@]} -gt 0 ]]; then
        if (( _force )); then
            info "${_label} specific files (ignoring exclusions): ${_unpack_files[*]}"
        else
            info "${_label} specific files: ${_unpack_files[*]}"
        fi
        for target_file in "${_unpack_files[@]}"; do
            # Skip empty entries
            [[ -z "$target_file" ]] && continue

            # target_file is a home-relative path, construct dotfiles path
            local dotfiles_file="${dotfiles_dir}/${target_file}"

            # Check if file exists in dotfiles directory
            if [[ ! -f "$dotfiles_file" ]] && [[ ! -d "$dotfiles_file" ]]; then
                if (( _force )); then
                    error "File not found in dotfiles directory: $target_file"
                    return 1
                else
                    warn "File not found in dotfiles directory: $target_file"
                    continue
                fi
            fi

            # Check if file should be excluded (only for regular unpack)
            if (( ! _force )) && should_exclude_file "$dotfiles_file"; then
                report "Skipping excluded file: $target_file (use -U to force unpack)"
                continue
            fi

            # Link the file
            link_if_needed "$dotfiles_file" || return 1
        done
    else
        # Unpack all files
        info "$_label_all"
        local find_output files
        # Shallow: depth-1 dotfiles entries only.  No prune needed — maxdepth 1
        # means find never descends anyway.  should_exclude_file() filters results.
        log_debug "shallow find: find $findoptd $dotfiles_dir $findopt -mindepth 1 -maxdepth 1 -name .[a-zA-Z]*"
        find_output=$(find $findoptd $dotfiles_dir $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*")
        files=(${(f)find_output})
        for file in "${files[@]}"; do
            [[ -n "$file" ]] || continue
            log_debug "shallow: considering $file"
            if (( ! _force )); then
                should_exclude_file "$file" 0 && continue
            fi
            link_if_needed "$file" || return 1
        done
        if (( _force )); then
            info "creating directory links (force)"
        else
            info "creating directory links"
        fi
        # Deep: prune excluded dirs then print all files/symlinks.
        # -mindepth 1 as a global flag (before expression) skips the root itself
        # but still lets -prune fire on depth-1 dirs like .git.  Works on both
        # BSD and GNU find.  link_if_needed is idempotent so overlap with the
        # shallow pass is harmless.
        if [[ ${#find_prune_args[@]} -gt 0 ]]; then
            log_debug "deep find (with prune): find $findoptd $dotfiles_dir -mindepth 1 $findopt ( ${find_prune_args[@]} ) -o ( -type f -o -type l ) -print"
            find_output=$(find $findoptd $dotfiles_dir -mindepth 1 $findopt \
                \( "${find_prune_args[@]}" \) -o \
                \( -type f -o -type l \) -print)
        else
            log_debug "deep find (no prune): find $findoptd $dotfiles_dir -mindepth 1 $findopt ( -type f -o -type l )"
            find_output=$(find $findoptd $dotfiles_dir -mindepth 1 $findopt \( -type f -o -type l \))
        fi
        files=(${(f)find_output})
        for file in "${files[@]}"; do
            [[ -n "$file" ]] || continue
            log_debug "deep: considering $file"
            if (( ! _force )); then
                should_exclude_file "$file" 0 && continue
            fi
            link_if_needed "$file" || return 1
        done
    fi
    return 0
}

# _setup_normalize_path_array <array_name> <label> [force_dest_rel]
#   Normalizes all paths in the named array to be relative to _setup_link_dest.
#   On failure, prints an error and returns 1.
_setup_normalize_path_array() {
    local _arr_name=$1 _label=$2 _force_dest_rel=${3:-0}
    local -a _result=()
    local _p _n
    eval "local -a _src=(\"\${${_arr_name}[@]}\")"
    for _p in "${_src[@]}"; do
        _n=$(normalize_path_to_dest_relative "$_p" "$_force_dest_rel") || {
            error "Failed to normalize ${_label} path: $_p"
            return 1
        }
        _result+=("$_n")
    done
    eval "${_arr_name}=(\"\${_result[@]}\")"
    return 0
}

# setup_run_all dir_override link_dest dry_run_bool quiet_bool [defyes_bool [defno_bool]]
#
#   Full action dispatch. Reads action arrays set by setup_core_main arg parsing:
#   ingest, setup, track, untrack, unpack, force_unpack,
#   unpack_files, force_unpack_files.
function setup_run_all() {
    _setup_excludes_files=( "${@[7,-1]}" )
    _setup_init "$1" "$2" "$3" "$4" "${5:-0}" "${6:-0}"

# Ingest is track + unpack
if [[ ${#ingest[@]} -gt 0 ]]; then
  unpack=("-u")
  unpack_files+=("${ingest[@]}")
  track+=("${ingest[@]}")
fi

# Normalize all paths to be relative to home directory
# This ensures consistent behavior whether paths are provided as absolute or relative
if [[ ${#ingest[@]} -gt 0 ]]; then
    _setup_normalize_path_array ingest "ingest" || return 1
fi

if [[ ${#track[@]} -gt 0 ]]; then
    _setup_normalize_path_array track "track" || return 1
fi

if [[ ${#untrack[@]} -gt 0 ]]; then
    _setup_normalize_path_array untrack "untrack" || return 1
fi

if [[ ${#unpack_files[@]} -gt 0 ]]; then
    # NOTE: unpack paths are implicitly home-relative
    _setup_normalize_path_array unpack_files "unpack" 1 || return 1
fi

if [[ ${#force_unpack_files[@]} -gt 0 ]]; then
    # NOTE: unpack paths are implicitly home-relative
    _setup_normalize_path_array force_unpack_files "force_unpack" 1 || return 1
fi

# Copy in files
if [[ ${#track[@]} -gt 0 ]]; then
  for file in ${track[@]}; do
    info "Copying in file $file"
            copy_in_if_needed $file || return 1
    # Git add needs the path relative to dotfiles directory
    safe_git -C $dotfiles_dir add "$file"
  done
fi

# Untrack files
if [[ ${#untrack[@]} -gt 0 ]]; then
  for file in ${untrack[@]}; do
    info "Untracking file $file"
            untrack_if_needed $file || return 1
  done
fi

if [[ ${#setup[@]} -gt 0 ]]; then
  info "Copying files in"
  local find_output files
  find_output=$(find $findoptd $_setup_link_dest $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*")
  files=(${(f)find_output})
  for file in "${files[@]}"; do
    [[ -n "$file" ]] || continue
    # Normalize the path to be home-relative
    local normalized
    if normalized=$(normalize_path_to_dest_relative "$file"); then
                copy_in_if_needed "$normalized" || return 1
      # For link_if_needed, we need the full dotfiles path
                link_if_needed "${dotfiles_dir}/${normalized}" || return 1
      safe_git -C $dotfiles_dir add -A
    else
      warn "Skipping file that is not under home: $file"
    fi
  done
fi

# Extract files
if [[ ${#unpack[@]} -gt 0 ]]; then
        _setup_do_unpack "${unpack_files[@]}"
fi

# Force extract files (ignores exclusions)
if [[ ${#force_unpack[@]} -gt 0 ]]; then
        _setup_do_unpack --force "${force_unpack_files[@]}"
      fi
}

# setup_find start_dir exclude_file
#
#   Print all files and symlinks under start_dir (no depth restriction),
#   combining the shallow dot-entry scan and deep file scan, filtered by
#   exclusions from exclude_file. Results are deduplicated and sorted.
#   Self-contained: loads its own exclusion rules, saves/restores globals.
function setup_find() {
    local start_dir="$1"
    local exclude_file="$2"

    local -a _fopt=() _foptd=()
    [[ "$(uname)" == "Darwin" ]] && _foptd+=("-s")

    local -a _saved_rules _saved_prune
    _setup_save_exclusion_state "$exclude_file"
    build_find_prune_args

    local find_output f
    local -a _seen=()

    # Shallow: top-level dot-entries (files and dirs)
    find_output=$(find $_foptd "$start_dir" $_fopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*")
    for f in ${(f)find_output}; do
        [[ -n "$f" ]] || continue
        should_exclude_file "$f" 0 && continue
        _seen+=("$f")
        print -- "$f"
    done

    # Deep: all files and symlinks (with prune), skipping anything already printed
    if [[ ${#find_prune_args[@]} -gt 0 ]]; then
        find_output=$(find $_foptd "$start_dir" -mindepth 1 $_fopt \
            \( "${find_prune_args[@]}" \) -o \
            \( -type f -o -type l \) -print )
    else
        find_output=$(find $_foptd "$start_dir" -mindepth 1 $_fopt \( -type f -o -type l \) )
    fi
    for f in ${(f)find_output}; do
        [[ -n "$f" ]] || continue
        # Skip entries already emitted by the shallow scan
        [[ ${_seen[(ie)$f]} -le ${#_seen[@]} ]] && continue
        should_exclude_file "$f" 0 && continue
        print -- "$f"
    done

    _setup_restore_exclusion_state
}

# setup_core_main "$@"
#
#   Single-repo entrypoint: parse argv, validate, and dispatch.
#   All arg-parsing logic lives here so the core lib is self-contained and
#   testable.  The multi-component orchestrator (setup.zsh) calls this for
#   the main dotfiles repo, then iterates hook setup_fns for components.
#
#   Callers that want a specific sub-operation (e.g. update.zsh's unpack
#   phase) should call setup_run_unpack / setup_run_force_unpack directly
#   rather than going through setup_core_main.
function setup_core_main() {
    local script_name="${${(%):-%x}:A}"

    function _setup_main_usage() {
        echo "Usage: $script_name ([-ingest path | -i path ...] | [-setup | -s]) [-unpack [file ...] | -u [file ...]] [-force-unpack [file ...] | -U [file ...]] [--untrack path | -t path ...] [--diff | -d] [--dry-run | -D] [--yes | y] [--no | -n] [--repo-dir <path>] [--link-dest <path>]"
        echo "  -s, --setup         Auto ingest dotfiles from ~/"
        echo "  -i, --ingest        Ingest files (track then link)"
        echo "  -t, --track         Track files"
        echo "  -x, --untrack       Untrack files"
        echo "  -u, --unpack        Unpack files (respects exclusions)"
        echo "  -U, --force-unpack  Force unpack files (ignores exclusions)"
        echo "  -D, --dry-run       Show what actions would be taken without making changes"
        echo "  -g, --debug         Enable debug logging (one line per file traversed)"
        echo "  --repo-dir <path>     Source repo root (default: auto-detected dotfiles dir)"
        echo "  --link-dest <path>    Where symlinks are planted (default: \$HOME)"
        echo ""
        echo "Examples:"
        echo "  $script_name -s -D           # Show what setup would do (dry run)"
        echo "  $script_name -u .vimrc -D    # Show what unpacking .vimrc would do"
        echo "  $script_name -i ~/.bashrc -D # Show what ingesting ~/.bashrc would do"
        echo "  $script_name --repo-dir /path/to/zdot --link-dest ~/.config/zdot -u somefile"
    }

    local -a ingest=() setup=() unpack=() force_unpack=()
    local -a unpack_files=() force_unpack_files=()
    local -a track=() untrack=() diff=() quiet=() dry_run=()
    local -a defyes=() defno=() debug_flag=()
     local -a opt_repo_dir=() opt_link_dest=() opt_excludes=()

    zmodload zsh/zutil
    zparseopts -D -E - i+:=ingest -ingest+:=ingest \
                       s=setup -setup=setup \
                       u=unpack -unpack=unpack \
                       U=force_unpack -force-unpack=force_unpack \
                       t+:=track -track+:=track \
                       x+:=untrack -untrack+:=untrack \
                       d=diff -d=diff \
                       q=quiet -q=quiet \
                       D=dry_run -dry-run=dry_run \
                       g=debug_flag -debug=debug_flag \
                       y=defyes -y=defyes \
                       n=defno -n=defno \
                       -repo-dir:=opt_repo_dir \
                        -link-dest:=opt_link_dest \
                        -excludes+:=opt_excludes || \
        { _setup_main_usage; unfunction _setup_main_usage; return 1; }

    # Strip flag tokens that zparseopts +: leaves interleaved with values
    ingest=( "${(@)ingest:#-i}" )
    ingest=( "${(@)ingest:#--ingest}" )
    track=( "${(@)track:#-t}" )
    track=( "${(@)track:#--track}" )
    untrack=( "${(@)untrack:#-x}" )
    untrack=( "${(@)untrack:#--untrack}" )
    force_unpack=( "${(@)force_unpack:#-U}" )
    force_unpack=( "${(@)force_unpack:#--force-unpack}" )
    opt_excludes=( "${(@)opt_excludes:#--excludes}" )

    # Remaining positional args go to the appropriate file list
    if [[ ${#unpack[@]} -gt 0 ]]; then
        unpack_files+=( "$@" )
    elif [[ ${#force_unpack[@]} -gt 0 ]]; then
        force_unpack_files+=( "$@" )
    fi

    if [[ ${#setup[@]} -eq 0 && ${#ingest[@]} -eq 0 && ${#track[@]} -eq 0 \
          && ${#untrack[@]} -eq 0 && ${#unpack[@]} -eq 0 && ${#force_unpack[@]} -eq 0 \
          && ${#diff[@]} -eq 0 ]]; then
        _setup_main_usage
        unfunction _setup_main_usage
        return 1
    fi

    unfunction _setup_main_usage

    [[ ${#debug_flag[@]} -gt 0 ]] && export DOTFILER_DEBUG=1
    [[ ${#quiet[@]} -gt 0 ]] && quiet_mode=true

    local _dry_run_bool=0 _quiet_bool=0 _defyes_bool=0 _defno_bool=0
    [[ ${#dry_run[@]} -gt 0 ]] && _dry_run_bool=1
    [[ ${#quiet[@]} -gt 0 ]]   && _quiet_bool=1
    [[ ${#defyes[@]} -gt 0 ]]  && _defyes_bool=1
    [[ ${#defno[@]} -gt 0 ]]   && _defno_bool=1

    setup_run_all "${opt_repo_dir[-1]:-}" "${opt_link_dest[-1]:-}" \
        "$_dry_run_bool" "$_quiet_bool" "$_defyes_bool" "$_defno_bool" \
        "${opt_excludes[@]}"
}

# setup_core_unload
#
#   Undefine all functions and globals set by setup_core.zsh.
#   Use this after in-process setup/unpack is complete (e.g. at the end of
#   update.zsh's unpack phase) to avoid polluting the caller's shell session
#   when setup_core.zsh has been sourced into a long-running process.
function setup_core_unload() {
    # Globals from _setup_init
    unset dotfiles_dir _setup_link_dest _setup_excludes_files
    unset dry_run quiet defyes defno
    unset findopt findoptd find_prune_args
    unset _gitignore_rules _prune_dir_names

    # All functions defined by this lib
    local fn
    for fn in \
        read_exclusion_patterns build_find_prune_args \
        _gitignore_match_single should_exclude_file \
         normalize_path_to_dest_relative prompt_yes_no \
         safe_mkdir safe_ln safe_rm safe_cp safe_cp_r safe_git \
         dolink link_if_needed copy_in_if_needed untrack_if_needed \
         _setup_init \
         _setup_normalize_path_array \
         _setup_save_exclusion_state _setup_restore_exclusion_state \
         setup_find_shallow setup_find_deep setup_find \
         setup_run_unpack _setup_do_unpack \
         setup_run_force_unpack \
         setup_run_all \
         setup_core_main \
         setup_core_unload
    do
        unfunction "$fn" 2>/dev/null
    done
}

# Pure library — no exec guard.  Sourced by setup.zsh, update.zsh, etc.
