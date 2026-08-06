# shellcheck shell=bash
# Shared curl and cert-handling functions for mTLS git sync.
# Sourced by on-discover.sh and sync-test.sh.
# Requires: set -euo pipefail, unset LD_LIBRARY_PATH (caller's responsibility).
# Expects these env vars to be set before calling the curl functions:
#   PEER_NETLOC  PEER_CERT_FILE  PEER_HOST  OUR_CERT  OUR_KEY

mtls_curl() {
    local path="$1"
    ensure_peer_host 2>/dev/null || true
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --max-time 5 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        -w '\nHTTP %{http_code}' \
        "https://${PEER_HOST}:${peer_port}${path}" 2>&1
}

mtls_curl_post() {
    local path="$1"
    local file="$2"
    ensure_peer_host 2>/dev/null || true
    local peer_ip="${PEER_NETLOC%%:*}" peer_port="${PEER_NETLOC##*:}"
    curl -sS --max-time 30 \
        --cacert "$PEER_CERT_FILE" \
        --cert "$OUR_CERT" --key "$OUR_KEY" \
        --data-binary "@$file" \
        --resolve "${PEER_HOST}:${peer_port}:${peer_ip}" \
        -w '\nHTTP %{http_code}' \
        "https://${PEER_HOST}:${peer_port}${path}" 2>&1
}

ensure_peer_host() {
    if [ ! -f "$PEER_CERT_FILE" ]; then
        echo "[discovery] PEER_CERT_FILE is not set or missing; cannot connect to peer" >&2
        return 1
    fi
    if [ -z "${PEER_HOST:-}" ]; then
        PEER_HOST=$(openssl x509 -in "$PEER_CERT_FILE" -noout -subject 2>/dev/null | \
            sed -n 's/.*CN\s*=\s*//p')
        [ -z "$PEER_HOST" ] && PEER_HOST="${PEER_NETLOC%%:*}"
    fi
}

# Apply a git bundle to a bare repository.
# Fetches into per-peer namespace, promotes branches, fetches tags, fixes HEAD.
# Args: <repo_dir> <bundle_file> <peer_host>
# Returns: 0 on success, 1 on failure
apply_bundle_to_repo() {
    repo_dir="$1" bundle_file="$2" peer_host="$3"
    remote_ns="refs/remotes/${peer_host}"

    # Create the bare repo if it doesn't exist yet.
    [ -d "$repo_dir" ] || git init --bare "$repo_dir"

    # 1. Fetch all incoming branches into the per-peer namespace.
    git -C "$repo_dir" fetch "$bundle_file" "+refs/heads/*:${remote_ns}/*" 2>&1 || return 1

    # 2. Promote incoming branches to local refs/heads when safe.
    while IFS= read -r ref; do
        branch="${ref#"${remote_ns}"/}"
        incoming="$(git -C "$repo_dir" rev-parse "$ref" 2>/dev/null)" || continue
        if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/${branch}" 2>/dev/null; then
            local_sha="$(git -C "$repo_dir" rev-parse "refs/heads/${branch}")"
            if git -C "$repo_dir" merge-base --is-ancestor "$local_sha" "$incoming" 2>/dev/null; then
                git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
            fi
        else
            git -C "$repo_dir" update-ref "refs/heads/${branch}" "$incoming"
        fi
    done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' "${remote_ns}/" 2>/dev/null || true)

    # 3. Fetch tags without force; skip conflicts silently.
    git -C "$repo_dir" fetch "$bundle_file" "refs/tags/*:refs/tags/*" 2>&1 || true

    # 4. Fix HEAD if it points to a nonexistent ref.
    first_branch=$(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/heads 2>/dev/null | head -1)
    if [ -n "$first_branch" ] && ! git -C "$repo_dir" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$repo_dir" symbolic-ref HEAD "$first_branch"
    fi
}

# Query the peer's spool coverage for a repo.
# Returns lines of "from-sha to-sha" for each spooled bundle.
query_spool_coverage() {
    local repo="$1"
    mtls_curl "/spool?repo=${repo}" 2>/dev/null | grep -E '^[0-9a-f]+ [0-9a-f]+$' || true
}
