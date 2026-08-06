#!/usr/bin/env python3
"""Generate source/version_.d from the version field in dub.json."""
import json
import sys
from pathlib import Path


def main():
    project_root = Path(__file__).parent.parent
    dub_json = project_root / "dub.json"
    try:
        with open(dub_json) as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error: could not read {dub_json}: {e}", file=sys.stderr)
        return 1

    version = data.get("version", "")
    if not version:
        print("Error: could not extract version from dub.json", file=sys.stderr)
        return 1

    version_file = project_root / "source" / "version_.d"
    version_file.write_text(f'module version_;\nenum appVersion = "{version}";\n')
    return 0


if __name__ == "__main__":
    sys.exit(main())
