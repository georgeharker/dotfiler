#!/bin/zsh

# Capture script name early before functions change context
script_name="${${(%):-%x}:A}"
helper_script_dir="${script_name:h}"

source "${helper_script_dir}/helpers.sh"

ingest=()
setup=()
unpack=()
force_unpack=()
untrack=()
diff=()

function usage(){
  echo "Usage: $script_name ([-ingest path | -i path ...] | [-setup | -s]) [-unpack [file ...] | -u [file ...]] [-force-unpack [file ...] | -U [file ...]] [--untrack path | -t path ...] [--diff | -d] [--dry-run | -D] [--yes | y] [--no | -n]"
  echo "  -u, --unpack        Unpack files (respects exclusions)"
  echo "  -U, --force-unpack  Force unpack files (ignores exclusions)"
  echo "  -D, --dry-run       Show what actions would be taken without making changes"
  echo ""
  echo "Examples:"
  echo "  $script_name -s -D           # Show what setup would do (dry run)"
  echo "  $script_name -u .vimrc -D    # Show what unpacking .vimrc would do"
  echo "  $script_name -i ~/.bashrc -D # Show what ingesting ~/.bashrc would do"
}

zmodload zsh/zutil
zparseopts -D -E - i+:=ingest -ingest+:=ingest \
                   s=setup -setup=setup \
                   u=unpack -unpack=unpack \
                   U=force_unpack -force-unpack=force_unpack \
                   t+:=untrack -untrack+:=untrack \
                   d=diff -d=diff \
                   q=quiet -q=quiet \
                   D=dry_run -dry-run=dry_run \
                   y=yes -y=defyes \
                   n=no -n=defno || \
  { usage; exit 1; }

# Set quiet mode for helpers
[[ ${#quiet[@]} -gt 0 ]] && quiet_mode=true

# Develop an expression for exclusion
# Function to read exclusion patterns from file or use defaults
read_exclusion_patterns() {
    local exclusion_file="$1"
    local -a path_patterns=()
    local -a name_patterns=()
    
    # Default exclusions if no file provided or file doesn't exist
    if [[ -z "$exclusion_file" ]] || [[ ! -f "$exclusion_file" ]]; then
        # Default path patterns (relative to dotfiles root)
        path_patterns=(
            ".git"
            ".git/*"
            ".nounpack"
            ".nounpack/*"
        )
        
        # Default name patterns (filenames to exclude anywhere)
        name_patterns=(
            "*.swp"
            "*.swo" 
            ".DS_Store"
            "*~"
        )
    else
        # Read file contents into array, splitting on newlines
        # (f) splits by line, (u) makes patterns unique, (ND) prevents globbing
        local -a raw_patterns=(${(fu)"$(<$exclusion_file)"}(ND))
        
        # Process each pattern
        for line in "${raw_patterns[@]}"; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.* ]] && continue
            [[ -z "$line" ]] && continue
            
            # Convert patterns similar to gitignore logic
            # Handle directory patterns (ending with /)
            if [[ "$line" =~ /$ ]]; then
                # Remove trailing slash and add both directory and contents
                local path_pattern="${line%/}"
                path_patterns+=("$path_pattern" "$path_pattern/*")
            # Handle patterns with path separators
            elif [[ "$line" =~ / ]]; then
                path_patterns+=("$line")
            # Handle name patterns (no path separators)
            else
                name_patterns+=("$line")
            fi
        done
    fi
    
    # Set global arrays
    excluded_paths=("${path_patterns[@]}")
    excluded_names=("${name_patterns[@]}")
}

# Function to build find exclusion arguments
build_find_exclusion_args() {
    local -a excludes=()
    
    # Build path exclusions
    for pattern in ${excluded_paths[@]}; do
        if [[ ${#excludes[@]} -gt 0 ]]; then
            excludes+=("-or")
        fi
        excludes+=("-path" "$dotfiles_dir/$pattern")
    done
    
    # Build name exclusions  
    for pattern in ${excluded_names[@]}; do
        if [[ ${#excludes[@]} -gt 0 ]]; then
            excludes+=("-or")
        fi
        excludes+=("-name" "$pattern")
    done
    
    # Set global exclude_args
    if [[ ${#excludes[@]} -gt 0 ]]; then
        exclude_args=("-and" "(" "-not" "(" ${excludes[@]} ")" ")")
    else
        exclude_args=()
    fi
}


ingest=("${(@)ingest:#-i}")
ingest=("${(@)ingest:#--ingest=}")
untrack=("${(@)untrack:#-t}")
untrack=("${(@)untrack:#--untrack}")
unpack=("${(@)unpack:#--unpack}")

force_unpack=("${(@)force_unpack:#-U}")
force_unpack=("${(@)force_unpack:#--force-unpack}")

# If unpack was specified, any remaining arguments are files to unpack
unpack_files=()
if [[ ${#unpack[@]} -gt 0 ]]; then
    unpack_files=("$@")
fi

# If force_unpack was specified, any remaining arguments are files to force unpack
force_unpack_files=()
if [[ ${#force_unpack[@]} -gt 0 ]]; then
    force_unpack_files=("$@")
fi

if (( ${#ingest[@]} == 0 && ${#setup[@]} == 0 && ${#unpack[@]} == 0 && ${#force_unpack[@]} == 0 && ${#untrack[@]} == 0 && ${#diff[@]} == 0 )); then
  usage
  exit 1
fi

# Detect script directory
dotfiles_dir=$(find_dotfiles_directory)

# Must be after dotfiles_dir detection
# Initialize exclusion patterns (can be called with custom file path)
# Usage: read_exclusion_patterns [/path/to/exclusion/file]
dotfiles_exclude_file=$(find_dotfiles_exclude_file)
read_exclusion_patterns "$dotfiles_exclude_file"
build_find_exclusion_args

# Indicate dry run mode if active
if [[ ${#dry_run[@]} -gt 0 ]]; then
    warn "=== DRY RUN MODE ACTIVE - No filesystem changes will be made ==="
fi

pretty_dotfiles_dir=`print -D $dotfiles_dir:P`

function prompt_yes_no(){
  [[ ${#defno[@]} -ge 1 ]] && exit 0
  [[ ${#defyes[@]} -ge 1 ]] && exit 1
  if read -qs "REPLY?$1? (N/y)"; then
    >&2 echo $REPLY; 
    exit 0
  fi
  >&2 echo $REPLY; 
  exit 1
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
  src=$1:A
  fullpath_dotfiles_dir=$dotfiles_dir:A
  dest="$HOME/"${1#$fullpath_dotfiles_dir/}
  info_nonl "checking $src to $dest .."
  if [[ -L "$dest" ]]; then
    linkfile=`readlink $dest`
    if [[ "$src" != "$linkfile" ]]; then
      error ".. Failed to link $src to $dest, conflicting link ($linkfile)"
    else
      info ".. ok"
    fi
  elif [[ -f "$dest" ]] && [[ -f "$src" ]]; then
    info ".. $dest exists checking contents for diffs"
    # check if the contents are the same
    diffs="${(f@)$(diff $src $dest)}"
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
    if `prompt_yes_no "$msg"`; then
      safe_rm $dest
      dolink $src $dest
    else
      warn ".. Refused link of $src to $dest"
      exit 0
    fi
  elif [[ -e "$dest" ]] && [[ -f "$src" ]]; then
    error ".. Refused link of $src to $dest, something in the way"
    exit 1
  elif [[ -d "$src" ]]; then
      if [[ -d "$dest" ]] || [[ ! -e "$dest" ]]; then
        info ".. skipping directory $dest"
      elif [[ -e "$dest" ]]; then
        error ".. Failed dest directory $dest exists as non directory"
        exit 1
      fi
  else
    dolink $src $dest
  fi
}

function copy_if_needed(){
  src=$1:A
  fullpath_home=$HOME:A
  fullpath_dotfiles_dir=$dotfiles_dir:A
  
  # SAFETY CHECK: Prevent re-ingesting symlinked files
  if [[ -L "$1" ]]; then
    link_target=$(readlink "$1")
    link_target_abs="${link_target:A}"
    if [[ "$link_target_abs" == "$fullpath_dotfiles_dir"* ]]; then
      info ".. SKIPPING: $1 is already a symlink to dotfiles ($link_target_abs)"
      return 0
    fi
  fi
  
  # Check if source is already in dotfiles directory
  if [[ "$src" == "$fullpath_dotfiles_dir"* ]]; then
    # Source is already in dotfiles, so we're probably re-ingesting from dotfiles to dotfiles
    # This shouldn't happen in normal usage, but let's handle it gracefully
    info ".. WARNING: Source $src is already in dotfiles directory"
    return 0
  else
    # Normal case: source is in home directory, copy to dotfiles
    # Calculate relative path from home directory
    if [[ "$src" == "$fullpath_home/"* ]]; then
      # File is under home directory - use relative path
      relative_path="${src#$fullpath_home/}"
      dest="${dotfiles_dir}/${relative_path}"
      if [ ! -d "$src" ]; then
          destdir="${dest:h}"
      else
          destdir="${dest}"
      fi
    else
      warn "WARNING: $src is not under home directory, placing in dotfiles root as $filename"
    fi
  fi
  
  info_nonl "checking $src to $dest ($destdir) .."
  if [[ -e "$dest" ]]; then
    info ".. $dest exists"
    # Oops it exists
    if [[ -f "$src" ]]; then
      info ".. checking contents for diffs"
      # check if the contents are the same
      diffs=`diff "$src" "$dest"`
      if [[ "$diffs" == "" ]]; then
        info ".. ok"
      else
        warn ".. File $dest exists and differs from $src"
        msg="Update tracked file $dest with contents from $src?"
        if `prompt_yes_no "$msg"`; then
          safe_cp "$src" "$dest"
          action ".. Updated $dest with contents from $src"
        else
          warn ".. Skipped updating $dest"
        fi
      fi
    elif [[ -d "$src" ]]; then
      info ".. checking directory contents for diffs"
      # Check if directory contents are the same
      diffs=`diff "$src" "$dest"`
      if [[ "$diffs" == "" ]]; then
        info ".. ok"
      else
        warn ".. Directory $dest exists and differs from $src"
        msg="Update tracked directory $dest with contents from $src?"
        if `prompt_yes_no "$msg"`; then
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
    if `prompt_yes_no "$msg"`; then
      safe_mkdir $destdir
      safe_cp_r $src $destdir
      action ".. Copied $src to $dest"
      safe_git -C "$dotfiles_dir" add "$dest"
    fi
  fi
  return 0
}

function untrack_if_needed(){
  file_path=$1
  
  # Convert to absolute path if relative
  if [[ "$file_path" == /* ]]; then
    # Already absolute path
    src=$file_path
  else
    # Relative path from dotfiles directory
    src="$dotfiles_dir/$file_path"
  fi
  
  src=$src:A
  fullpath_dotfiles_dir=$dotfiles_dir:A
  
  # Ensure the file is within the dotfiles directory
  if [[ "$src" != "$fullpath_dotfiles_dir"* ]]; then
    error "File $src is not within dotfiles directory $fullpath_dotfiles_dir"
    exit 1
  fi
  
  # Calculate the relative path within dotfiles
  relative_path="${src#$fullpath_dotfiles_dir/}"
  home_path="$HOME/$relative_path"
  
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
    safe_git -C "$dotfiles_dir" rm "$relative_path"
    action ".. Removed $src from git tracking"
  elif [[ -d "$src" ]]; then
    # Handle directory removal
    safe_git -C "$dotfiles_dir" rm -r "$relative_path"
    action ".. Removed directory $src from git tracking"
  else
    error ".. File $src does not exist"
    exit 1
  fi
}

# Enhanced exclusion checking function
function should_exclude_file(){
  local file_path="$1"
  local abs_file_path="${file_path:A}"
    local dotfiles_dir_abs="${dotfiles_dir:A}"
    
    # Get relative path from dotfiles directory for path pattern matching
    local relative_path=""
    if [[ "$abs_file_path" == "$dotfiles_dir_abs"* ]]; then
        relative_path="${abs_file_path#$dotfiles_dir_abs/}"
    fi
    
    # Check against excluded path patterns
    for pattern in ${excluded_paths[@]}; do
        # Check if pattern contains wildcards
        if [[ "$pattern" == *"*"* ]] || [[ "$pattern" == *"?"* ]] || [[ "$pattern" == *"["* ]]; then
            # Pattern contains wildcards - use glob matching against relative path
            if [[ -n "$relative_path" ]] && [[ "$relative_path" == ${~pattern} ]]; then
                return 0  # Should exclude
            fi
        else
            # Literal path - do exact matching
            local full_pattern_path="$dotfiles_dir_abs/$pattern"
            if [[ "$abs_file_path" == "${full_pattern_path:A}" ]]; then
                return 0  # Should exclude
            fi
    fi
  done
  
    # Check against excluded name patterns
    local basename="${abs_file_path:t}"  # Get just the filename
    for pattern in ${excluded_names[@]}; do
        # Use zsh pattern matching for name patterns
        if [[ "$basename" == ${~pattern} ]]; then
      return 0  # Should exclude
    fi
  done
  
  return 1  # Should not exclude
}

findopt=("-depth")
findoptd=()
if [[ `uname` == "Darwin" ]]; then
  findoptd+=("-s")
fi

# Copy in files
if [[ ${#ingest[@]} -gt 0 ]]; then
  for file in ${ingest[@]}; do
    info "Copying files in $file"
    copy_if_needed $file || exit 1
    safe_git -C $dotfiles_dir add $file
  done
  #  git -C $dotfiles_dir commit
fi

# Untrack files
if [[ ${#untrack[@]} -gt 0 ]]; then
  for file in ${untrack[@]}; do
    info "Untracking file $file"
    untrack_if_needed $file || exit 1
  done
fi

if [[ ${#setup[@]} -gt 0 ]]; then
  info "Copying files in"
  local find_output files
  find_output=$(find $findoptd $HOME $findopt -name "\.[a-zA-Z]*" -maxdepth 1 -mindepth 1 $exclude_args)
  files=(${(f)find_output})
  for file in "${files[@]}"; do
    [[ -n "$file" ]] || continue
    copy_if_needed "$file" || exit 1
    link_if_needed "$file" || exit 1
    safe_git -C $dotfiles_dir add -A
    # git -C $dotfiles_dir commit
  done
fi

# Extract files
if [[ ${#unpack[@]} -gt 0 ]]; then
  # Check if specific files were provided
  if [[ ${#unpack_files[@]} -gt 0 ]]; then
    # Unpack specific files
    info "Linking specific files: ${unpack_files[*]}"
    for target_file in ${unpack_files[@]}; do
      # Skip empty entries
      [[ -z "$target_file" ]] && continue
      
      # Check if file exists in dotfiles directory
      if [[ ! -f "$dotfiles_dir/$target_file" ]] && [[ ! -d "$dotfiles_dir/$target_file" ]]; then
        warn "File not found in dotfiles directory: $target_file"
        continue
      fi
      
      # Check if file should be excluded (only for regular unpack, not force unpack)
      if should_exclude_file "$dotfiles_dir/$target_file"; then
        warn "Skipping excluded file: $target_file (use -U to force unpack)"
        continue
      fi
      
      file_found=false
      
      # Check if it's a direct match in dotfiles_dir
      if [[ -f "$dotfiles_dir/$target_file" ]]; then
        link_if_needed "$dotfiles_dir/$target_file" || exit 1
        file_found=true
      else
        # Search for the file in subdirectories
        local find_output files
        find_output=$(find $findoptd $dotfiles_dir $findopt -name "$target_file" -type f $exclude_args)
        files=(${(f)find_output})
        for file in "${files[@]}"; do
          [[ -n "$file" ]] || continue
          link_if_needed "$file" || exit 1
          file_found=true
        done
      fi
      
      if [[ "$file_found" == "false" ]]; then
        error "File $target_file not found in dotfiles directory"
        exit 1
      fi
    done
  else
    # Unpack all files (existing behavior)
    info "Linking all files"
    local find_output files
    find_output=$(find $findoptd $dotfiles_dir $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*" $exclude_args)
    files=(${(f)find_output})
    for file in "${files[@]}"; do
      [[ -n "$file" ]] || continue
      link_if_needed "$file" || exit 1
  done
  info "creating directory links"
    find_output=$(find $findoptd $dotfiles_dir $findopt -mindepth 2 -and -type f $exclude_args)
    files=(${(f)find_output})
    for file in "${files[@]}"; do
      [[ -n "$file" ]] || continue
      link_if_needed "$file" || exit 1
  done
fi
fi

# Force extract files (ignores exclusions)
if [[ ${#force_unpack[@]} -gt 0 ]]; then
  # Check if specific files were provided
  if [[ ${#force_unpack_files[@]} -gt 0 ]]; then
    # Force unpack specific files (ignore exclusions)
    info "Force linking specific files (ignoring exclusions): ${force_unpack_files[*]}"
    for target_file in ${force_unpack_files[@]}; do
      # Skip empty entries
      [[ -z "$target_file" ]] && continue
      
      file_found=false
      
      # Check if it's a direct match in dotfiles_dir
      if [[ -f "$dotfiles_dir/$target_file" ]]; then
        link_if_needed "$dotfiles_dir/$target_file" || exit 1
        file_found=true
      else
        # Search for the file in subdirectories (without exclusions)
        local find_output files
        find_output=$(find $findoptd $dotfiles_dir $findopt -name "$target_file" -type f)
        files=(${(f)find_output})
        for file in "${files[@]}"; do
          [[ -n "$file" ]] || continue
          link_if_needed "$file" || exit 1
          file_found=true
        done
      fi
      
      if [[ "$file_found" == "false" ]]; then
        error "File $target_file not found in dotfiles directory"
        exit 1
      fi
    done
  else
    # Force unpack all files (ignore exclusions)
    info "Force linking all files (ignoring exclusions)"
    local find_output files
    find_output=$(find $findoptd $dotfiles_dir $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*")
    files=(${(f)find_output})
    for file in "${files[@]}"; do
      [[ -n "$file" ]] || continue
      link_if_needed "$file" || exit 1
    done
    info "creating directory links (force)"
    find_output=$(find $findoptd $dotfiles_dir $findopt -mindepth 2 -and -type f)
    files=(${(f)find_output})
    for file in "${files[@]}"; do
      [[ -n "$file" ]] || continue
      link_if_needed "$file" || exit 1
    done
  fi
fi
