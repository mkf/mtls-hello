#!/bin/bash
# Shared safe-deletion helpers. Sourced by scripts; not executed directly.
#
# Rule: never use `rm -rf` / `rm -f` / `rm -r`, and never use `find` to delete.
# Only plain `rm` on known files (or globs anchored to a known path) and
# `rmdir` on known (empty) directories. Errors are never hidden with
# `2>/dev/null`: anything that cannot be removed is reported on stderr.

# Remove a single known file or symlink (no -f, no -r). No-op if absent.
# Usage: remove_file_safe <path>...
remove_file_safe() {
    local f
    for f in "$@"; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            if ! rm -- "$f"; then
                echo "remove_file_safe: could not remove '$f'" >&2
            fi
        fi
    done
}

# Remove a git repository directory (bare or normal) using only rm + rmdir.
# A git repo's layout is known, so all globs are anchored to the repo path.
# For a normal (non-bare) repo, the git internals live under <repo>/.git and
# the working-tree files are the caller's responsibility (they know them).
# nullglob ensures an unmatched glob expands to nothing, so `rm`/`rmdir` are
# never invoked with no operands. Failures surface on stderr and are also
# reported; the function never aborts the caller.
# Usage: remove_git_repo <repo-dir>
remove_git_repo() {
    local repo="${1:-}"
    [ -n "$repo" ] || return 0
    [ -d "$repo" ] || return 0
    case "$repo" in
        /|//|/*/*) : ;;        # require at least two path components
        *) echo "remove_git_repo: refusing to touch '$repo'" >&2; return 0 ;;
    esac

    local gitdir="$repo"
    if [ -d "$repo/.git" ]; then
        gitdir="$repo/.git"
    fi

    local shopt_was
    shopt_was="$(shopt -p nullglob 2>&1 || true)"
    shopt -s nullglob

    local f d
    for f in "$gitdir"/HEAD "$gitdir"/config "$gitdir"/description \
             "$gitdir"/packed-refs "$gitdir"/FETCH_HEAD "$gitdir"/index \
             "$gitdir"/MERGE_HEAD "$gitdir"/ORIG_HEAD; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if ! rm -- "$f"; then
            echo "remove_git_repo: could not remove '$f'" >&2
        fi
    done

    for f in "$gitdir"/refs/heads/* "$gitdir"/refs/tags/* \
             "$gitdir"/refs/remotes/*/* "$gitdir"/logs/heads/* "$gitdir"/logs/refs/*/* \
             "$gitdir"/objects/??/* "$gitdir"/objects/pack/* "$gitdir"/objects/info/* \
             "$gitdir"/hooks/* "$gitdir"/info/*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        if ! rm -- "$f"; then
            echo "remove_git_repo: could not remove '$f'" >&2
        fi
    done

    for d in "$gitdir"/objects/?? "$gitdir"/objects/pack "$gitdir"/objects/info \
             "$gitdir"/refs/heads "$gitdir"/refs/tags "$gitdir"/refs/remotes/* "$gitdir"/refs/remotes \
             "$gitdir"/logs/heads "$gitdir"/logs/refs/* "$gitdir"/logs/refs \
             "$gitdir"/objects "$gitdir"/refs "$gitdir"/logs \
             "$gitdir"/hooks "$gitdir"/info "$gitdir"/branches "$gitdir"/rr-cache; do
        [ -d "$d" ] || continue
        if ! rmdir -- "$d"; then
            echo "remove_git_repo: could not rmdir '$d' (not empty?)" >&2
        fi
    done

    if [ "$gitdir" != "$repo" ]; then
        if ! rmdir -- "$gitdir"; then
            echo "remove_git_repo: could not rmdir '$gitdir' (non-empty leftovers)" >&2
        fi
    fi

    if ! rmdir -- "$repo"; then
        echo "remove_git_repo: could not fully remove '$repo' (working-tree leftovers)" >&2
    fi

    eval "$shopt_was" 2>&1 || true
}
