# Data Model: Bundle Spooling

## Spool directory layout

```
<data-dir>/spool/
├── laptops/
│   ├── 0000000000000000000000000000000000000000-abc123def456.bundle
│   └── abc123def456-def789abc012.bundle
├── other-repo/
│   └── 0000000000000000000000000000000000000000-aaa111bbb222.bundle
└── ...
```

## Bundle file naming

| Component | Value | Example |
|---|---|---|
| from-sha | Parent of first commit in bundle (or all-zeros for full history) | `0000...0000` |
| to-sha | Last commit (tip) in bundle | `abc123def456` |
| Filename | `<from-sha>-<to-sha>.bundle` | `0000000000000000000000000000000000000000-abc123def456.bundle` |
| Temp file | `<from-sha>-<to-sha>.bundle.tmp` (during write) | same + `.tmp` |

## GET /spool?repo=name response

```
0000000000000000000000000000000000000000 abc123def456
abc123def456 def789abc012
```

One line per spooled bundle: `from-sha to-sha`.

## Entities

| Entity | Fields | Purpose |
|---|---|---|
| SpooledBundle | repo, from-sha, to-sha, filepath | A bundle waiting to be merged |
| CoverageReport | repo, list of (from-sha, to-sha) | What the peer already has spooled |
| MergeResult | repo, applied[], skipped[], errors[] | Output of merge-spool.sh |

## State transitions

```
Bundle POSTed → .tmp file written → renamed to .bundle → [spooled]
                                                ↓
                                    merge-spool.sh runs
                                                ↓
                                    git fetch + promote → [applied]
                                                ↓
                                    .bundle file deleted → [cleaned]
```
