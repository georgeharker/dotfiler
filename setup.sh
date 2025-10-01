#!/bin/zsh

ingest=()
setup=()
unpack=()
force_unpack=()
untrack=()
diff=()

function usage(){
  echo "Usage: $0 ([-ingest path | -i path ...] | [-setup | -s]) [-unpack [file ...] | -u [file ...]] [-force-unpack [file ...] | -U [file ...]] [--untrack path | -t path ...] [--diff | -d] [--yes | y] [--no | -n]"
  echo "  -u, --unpack        Unpack files (respects exclusions)"
  echo "  -U, --force-unpack  Force unpack files (ignores exclusions)"
}

zmodload zsh/zutil
zparseopts -D -E - i+:=ingest -ingest+:=ingest \
                   s=setup -setup=setup \
                   u=unpack -unpack=unpack \
                   U=force_unpack -force-unpack=force_unpack \
                   t+:=untrack -untrack+:=untrack \
                   d=diff -d=diff \
                   q=quiet -q=quiet \
                   y=yes -y=defyes \
                   n=yes -n=defno || \
  (usage; exit 1)

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

if (( ${#ingest[@]} == 0 && ${#setup[@]} == 0 && ${#unpack[@]} == 0 && ${#force_unpack[@]} == 0 && ${#untrack[@]} == 0 )); then
  usage
  exit 1
fi


script_dir=`dirname $0`
script_dir=$script_dir:A

# Allow override of dotfiles directory via zstyle
zstyle -s ':dotfiles:directory' path dotfiles_override
if [[ -n "$dotfiles_override" ]]; then
  script_dir="${dotfiles_override:A}"
fi

pretty_script_dir=`print -D $script_dir:P`

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

function info(){
    [[ ${#quiet[@]} == 0 ]] && print -P "$@"
}
function info_nonl(){
    [[ ${#quiet[@]} == 0 ]] && print -n -P "$@"
}
function action(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{blue}$@%f"
}
function error(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{red}$@%f"
}
function warn(){
    [[ ${#quiet[@]} == 0 ]] && print -P "%F{yellow}$@%f"
}

function dolink(){
  src=$1
  dest=$2
  destdir=`dirname $dest`
  mkdir -p $destdir
  ln -s $src $destdir/
  action ".. Linked $src to $dest"
}

function link_if_needed(){
  src=$1:A
  fullpath_script_dir=$script_dir:A
  dest="$HOME/"${1#$fullpath_script_dir/}
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
      rm $dest
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
  fullpath_script_dir=$script_dir:A
  
  # Check if source is already in dotfiles directory
  if [[ "$src" == "$fullpath_script_dir"* ]]; then
    # Source is already in dotfiles, so we're probably re-ingesting from dotfiles to dotfiles
    # This shouldn't happen in normal usage, but let's handle it gracefully
    info ".. WARNING: Source $src is already in dotfiles directory"
    return 0
  else
    # Normal case: source is in home directory, copy to dotfiles
    dest="$script_dir/"${src#$fullpath_home/}
    destdir="$script_dir/"`dirname ${src#$fullpath_home/}`
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
          cp "$src" "$dest"
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
          cp -r "$src"/* "$dest"/
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
      mkdir -p $destdir
      cp -r $src $destdir
      action ".. Copied $src to $dest"
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
    src="$script_dir/$file_path"
  fi
  
  src=$src:A
  fullpath_script_dir=$script_dir:A
  
  # Ensure the file is within the dotfiles directory
  if [[ "$src" != "$fullpath_script_dir"* ]]; then
    error "File $src is not within dotfiles directory $fullpath_script_dir"
    exit 1
  fi
  
  # Calculate the relative path within dotfiles
  relative_path="${src#$fullpath_script_dir/}"
  home_path="$HOME/$relative_path"
  
  info_nonl "untracking $src (home: $home_path) .."
  
  if [[ -f "$src" ]]; then
    # Remove symlink from home if it exists and points to this file
    if [[ -L "$home_path" ]]; then
      link_target=$(readlink "$home_path")
      if [[ "$link_target" == "$src" ]]; then
        rm "$home_path"
        action ".. Removed symlink $home_path"
      else
        warn ".. Symlink $home_path points to different target: $link_target"
      fi
    elif [[ -f "$home_path" ]]; then
      warn ".. $home_path exists but is not a symlink"
    fi
    
    # Remove from git and filesystem
    git -C "$script_dir" rm "$relative_path"
    action ".. Removed $src from git tracking"
  elif [[ -d "$src" ]]; then
    # Handle directory removal
    git -C "$script_dir" rm -r "$relative_path"
    action ".. Removed directory $src from git tracking"
  else
    error ".. File $src does not exist"
    exit 1
  fi
}

# Develop an expression for exclusion
# Centralized exclusion configuration
excluded_paths=(
  ".git"
  "setup.sh"
  "install.sh"
  "update.sh"
  "check_update.sh"
  ".nounpack"
)
exclude_suffixes=".*.swp,.*.swo,.DS_Store"

function should_exclude_file(){
  local file_path="$1"
  local abs_file_path="${file_path:A}"
  
  # Check against excluded paths using centralized config
  for excluded in ${excluded_paths[@]}; do
    local full_excluded_path="$script_dir/$excluded"
    if [[ "$abs_file_path" == "${full_excluded_path:A}" ]] || [[ "$abs_file_path" == "${full_excluded_path:A}/"* ]]; then
      return 0  # Should exclude
    fi
  done
  
  # Check excluded suffixes
  local excluded_suffixes=(".swp" ".swo" ".DS_Store")
  for suffix in ${excluded_suffixes[@]}; do
    if [[ "$file_path" == *"$suffix" ]]; then
      return 0  # Should exclude
    fi
  done
  
  return 1  # Should not exclude
}

# Build find exclusion args from centralized config
excludes=()
for excluded in ${excluded_paths[@]}; do
  if [[ ${#excludes[@]} -gt 0 ]]; then
    excludes+=("-or")
  fi
  excludes+=("-path" "$script_dir/$excluded")
  # Also exclude subdirectories for .git and .nounpack
  if [[ "$excluded" == ".git" ]] || [[ "$excluded" == ".nounpack" ]]; then
    excludes+=("-or" "-path" "$script_dir/$excluded/*")
  fi
done

# Add suffix exclusions to find args
a=("${(@s/,/)exclude_suffixes}")
for x in $a; do
  if [[ ${#excludes[@]} -gt 0 ]]; then
    excludes+=("-or" "-name" "$x")
  else
    excludes+=("-name" "$x")
  fi
done

exclude_args=()
if [[ ${#excludes[@]} -gt 0 ]]; then
  exclude_args=("-and" "(" "-not" "(" ${excludes[@]} ")" ")")
fi

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
  done
  git -C $script_dir add -A
  #  git -C $script_dir commit
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
  find $findoptd $HOME $findopt -name "\.[a-zA-Z]*" -maxdepth 1 -mindepth 1 $exclude_args | while read -r file
  do
    copy_if_needed $file  || exit 1
    link_if_needed $file  || exit 1
    git -C $script_Dir add -A
    # git -C $script_dir commit
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
      if [[ ! -f "$script_dir/$target_file" ]] && [[ ! -d "$script_dir/$target_file" ]]; then
        warn "File not found in dotfiles directory: $target_file"
        continue
      fi
      
      # Check if file should be excluded (only for regular unpack, not force unpack)
      if should_exclude_file "$script_dir/$target_file"; then
        warn "Skipping excluded file: $target_file (use -U to force unpack)"
        continue
      fi
      
      file_found=false
      
      # Check if it's a direct match in script_dir
      if [[ -f "$script_dir/$target_file" ]]; then
        link_if_needed "$script_dir/$target_file" || exit 1
        file_found=true
      else
        # Search for the file in subdirectories
        find $findoptd $script_dir $findopt -name "$target_file" -type f $exclude_args | while read -r file
        do
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
  find $findoptd $script_dir $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*" $exclude_args | while read -r file
  do
    link_if_needed $file || exit 1
  done
  info "creating directory links"
  find $findoptd $script_dir $findopt -mindepth 2  -and -type f $exclude_args | while read -r file
  do
    link_if_needed $file || exit 1
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
      
      # Check if it's a direct match in script_dir
      if [[ -f "$script_dir/$target_file" ]]; then
        link_if_needed "$script_dir/$target_file" || exit 1
        file_found=true
      else
        # Search for the file in subdirectories (without exclusions)
        find $findoptd $script_dir $findopt -name "$target_file" -type f | while read -r file
        do
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
    find $findoptd $script_dir $findopt -mindepth 1 -maxdepth 1 -name "\.[a-zA-Z]*" | while read -r file
    do
      link_if_needed $file || exit 1
    done
    info "creating directory links (force)"
    find $findoptd $script_dir $findopt -mindepth 2  -and -type f | while read -r file
    do
      link_if_needed $file || exit 1
    done
  fi
fi