# CLI Contract: Bundle Spooling

## POST /bundle?repo=<name>&host=<peer>&from=<sha>&to=<sha>

Receives a git bundle and spools it to `<data-dir>/spool/<name>/<from>-<to>.bundle`.

**Query parameters**:
- `repo` (required): repository name without `.git`
- `host` (required): sending peer's hostname (for remote namespace)
- `from` (optional): parent SHA of first commit in bundle. If missing, computed from bundle.
- `to` (optional): tip SHA of bundle. If missing, computed from bundle.

**Request body**: raw git bundle data (binary)

**Response**: `200 spooled` (new server) or `200 ok` (old server, applied immediately)

**Backward compatibility**: Old senders without `from`/`to` params still work — server computes them from `git bundle list-heads`.

---

## GET /spool?repo=<name>

Lists covered commit ranges from the spool directory.

**Query parameters**:
- `repo` (required): repository name

**Response**: plain text, one line per spooled bundle:
```
<from-sha> <to-sha>
```

**Status**: 200 on success, 404 if no spool directory for this repo.

---

## scripts/merge-spool.sh [repo-name]

Applies all spooled bundles to their bare repositories.

**Arguments**:
- `repo-name` (optional): merge only this repo. If omitted, merge all repos in the spool directory.

**Environment**:
- `REPOS_ROOT`: directory containing bare repositories
- The spool directory is derived relative to the script: `$(dirname "$0")/../spool/`

**Output**: For each bundle:
```
[repo] applying abc-def.bundle
[repo] promoted main: abc123 -> def456
[repo] applied abc-def.bundle
```
Or on skip:
```
[repo] skipping abc-def.bundle: missing parent commit abc123
```

**Exit codes**: 0 if all bundles applied or skipped cleanly, 1 if any error.
