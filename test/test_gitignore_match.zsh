#!/usr/bin/env zsh
# test_gitignore_match.zsh — exhaustive tests for _gitignore_match_single()
#
# Sources setup.zsh directly (ZSH_EVAL_CONTEXT guards skip the script body).
# Tests the production function from a single authoritative copy.
setopt extendedglob

source "${0:h}/../setup.zsh"

# Thin alias so test calls read naturally.
gitignore_match() { _gitignore_match_single "$@"; }

typeset -i pass=0 fail=0

# Use printf for all output to avoid zsh print option-parsing on --- strings.
section() { printf '\n--- %s ---\n' "$1"; }

check() {
    local desc="$1" pattern="$2" path="$3" is_dir="${4:-0}" expect="$5"
    gitignore_match "$pattern" "$path" "$is_dir"
    local rc=$?
    local got="keep"; (( rc == 0 )) && got="exclude"
    if [[ "$got" == "$expect" ]]; then
        (( pass++ ))
    else
        printf 'FAIL  %s\n' "$desc"
        printf '      pattern=%-30s  path=%s  is_dir=%s\n' "$pattern" "$path" "$is_dir"
        printf '      got=%-10s  want=%s\n' "$got" "$expect"
        (( fail++ ))
    fi
}

# ---------------------------------------------------------------------------
section "FP1: unanchored bare name"
check "basename match"                  ".mypy_cache"    ".mypy_cache"               0  exclude
check "basename in subdir"              ".mypy_cache"    "foo/.mypy_cache"            0  exclude
check "basename deep"                   ".mypy_cache"    "a/b/c/.mypy_cache"          0  exclude
check "no partial component match"      ".mypy_cache"    "foo/.mypy_cache_extra"      0  keep
check "no prefix component match"       ".mypy_cache"    "foo/x.mypy_cache"           0  keep

section "FP1: unanchored glob name"
check "*.swp basename"                  "*.swp"          "foo.swp"                    0  exclude
check "*.swp in subdir"                 "*.swp"          "a/b/foo.swp"                0  exclude
check "*.swp no wrong ext"              "*.swp"          "a/b/foo.swap"               0  keep
check ".DS_Store literal"               ".DS_Store"      "a/.DS_Store"                0  exclude
check "#*# glob"                        "#*#"            ".emacs.d/#init.el#"         0  exclude

section "FP1: unanchored literal dir contents"
check "literal: file inside"            ".mypy_cache"    ".mypy_cache/foo.py"         0  exclude
check "literal: deep inside"            ".mypy_cache"    ".mypy_cache/a/b/c.py"       0  exclude
check "literal: subdir inside"          ".mypy_cache"    "pkg/.mypy_cache/foo.py"     0  exclude

section "FP1: unanchored dir_only (trailing /)"
check "dir-only: dir itself"            ".mypy_cache/"   ".mypy_cache"               1  exclude
check "dir-only: file inside"           ".mypy_cache/"   ".mypy_cache/foo.py"         0  exclude
check "dir-only: deep inside"           ".mypy_cache/"   ".mypy_cache/a/b/foo.py"     0  exclude
check "dir-only: subdir's file"         "node_modules/"  "pkg/node_modules/x.js"      0  exclude
check "dir-only: subdir deep"           "node_modules/"  "pkg/node_modules/a/b.js"    0  exclude
check "dir-only: dir itself subdir"     "node_modules/"  "pkg/node_modules"           1  exclude
check "dir-only: not a plain file"      ".mypy_cache/"   "other_cache"               0  keep
check "dir-only: not same-prefix name"  ".mypy_cache/"   ".mypy_cache_extra"         1  keep
check "dir-only: not is_dir=0 bare"     ".mypy_cache/"   ".mypy_cache"               0  keep

section "FP2: anchored literal"
check "root dir excluded"               "/.nounpack"     ".nounpack"                  0  exclude
check "root dir contents"               "/.nounpack"     ".nounpack/foo"              0  exclude
check "root dir deep contents"          "/.nounpack"     ".nounpack/a/b/c"            0  exclude
check "not in subdir"                   "/.nounpack"     "a/.nounpack"                0  keep
check "interior slash anchors"          ".config/karabiner" ".config/karabiner"       0  exclude
check "interior slash contents"         ".config/karabiner" ".config/karabiner/x"     0  exclude
check "interior slash no subdir"        ".config/karabiner" "a/.config/karabiner"     0  keep
check "root file excluded"              "/dotfiles_exclude" "dotfiles_exclude"         0  exclude
check "root file no subdir"             "/dotfiles_exclude" "sub/dotfiles_exclude"     0  keep

section "FP4: anchored * (not **)"
check "/* depth-1 match"                ".codecompanion/*"  ".codecompanion/progress"        0  exclude
check "/* no cross-slash"               ".codecompanion/*"  ".codecompanion/progress/foo"     0  keep
check "/* glob"                         "src/*.c"           "src/main.c"                      0  exclude
check "/* glob no cross"                "src/*.c"           "src/lib/util.c"                  0  keep
check "/? single char"                  "a/?"               "a/x"                             0  exclude
check "/? no multi"                     "a/?"               "a/xy"                            0  keep

section "FP4: dir_only with *"
check "/*/ dir itself"                  ".codecompanion/*/" ".codecompanion/foo"      1  exclude
check "/*/ file inside"                 ".codecompanion/*/" ".codecompanion/foo/bar"  0  exclude
check "/*/ deep inside"                 ".codecompanion/*/" ".codecompanion/a/b/c"    0  exclude

section "FP3: anchored ** — trailing"
check "foo/** contents"                 "foo/**"         "foo/bar"                    0  exclude
check "foo/** deep"                     "foo/**"         "foo/a/b/c"                  0  exclude
check "foo/** not the dir itself"       "foo/**"         "foo"                        0  keep
check "foo/** not sibling"              "foo/**"         "foobar/x"                   0  keep

section "FP3: anchored ** — leading"
check "**/foo at root"                  "**/foo"         "foo"                        0  exclude
check "**/foo in subdir"                "**/foo"         "a/b/foo"                    0  exclude
check "**/foo not foo/bar"              "**/foo"         "foo/bar"                    0  keep
check "**/foo not partial"              "**/foo"         "foobar"                     0  keep
check "**/*.c at root"                  "**/*.c"         "main.c"                     0  exclude
check "**/*.c deep"                     "**/*.c"         "src/lib/util.c"             0  exclude

section "FP3: anchored ** — interior"
check "a/**/b zero middle"              "a/**/b"         "a/b"                        0  exclude
check "a/**/b one middle"               "a/**/b"         "a/x/b"                      0  exclude
check "a/**/b two middle"               "a/**/b"         "a/x/y/b"                    0  exclude
check "a/**/b not a/b/extra"            "a/**/b"         "a/b/extra"                  0  keep
check "a/**/b not c/a/b"               "a/**/b"         "c/a/b"                      0  keep

section "FP3: dir_only with **"
check "foo/**/ contents"                "foo/**/"        "foo/bar/baz"                0  exclude
check "**/logs/ file inside"            "**/logs/"       "a/logs/app.log"             0  exclude
check "**/logs/ dir itself"             "**/logs/"       "a/logs"                     1  exclude

section "Edge cases"
check "empty pattern"                   ""               "foo"                        0  keep
check "slash-only pattern"              "/"              "foo"                        0  keep
check "root dot-file"                   "/.bashrc"       ".bashrc"                    0  exclude
check "root dot-file no subdir"         "/.bashrc"       "sub/.bashrc"                0  keep
check "pattern longer than path"        "a/b/c/d"        "a/b"                        0  keep
check "exact deep literal"              "a/b/c"          "a/b/c"                      0  exclude
check "exact deep literal contents"     "a/b/c"          "a/b/c/d"                    0  exclude
check "glob in middle segment"          "a/*/c"          "a/x/c"                      0  exclude
check "glob in middle no cross"         "a/*/c"          "a/x/y/c"                    0  keep

printf '\n%d passed, %d failed\n' $pass $fail
(( fail == 0 ))
