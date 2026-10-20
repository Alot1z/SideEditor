#!/usr/bin/env python3
"""Write the SideEditorCore test manifest.

The manifest is the evidence record for the `lint-and-test` job: it names the
commit the tests ran against, the toolchain that compiled them, a hash of the
fixture corpus, and the test counts parsed out of the log. It is uploaded as an
artifact so a green run can be tied to specific inputs instead of "CI passed".

A missing test log is not an error here — the step that writes the manifest runs
with `if: always()`, and a manifest that says `tests: null` plus the uploaded log
is more useful than a second failure that hides the first.

Usage:
    python3 scripts/ci/sideeditor_test_manifest.py \
        --log sideeditor-core-tests.log \
        --output sideeditor-test-manifest.json
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "SideEditor" / "SideEditorCore"
FIXTURES = PACKAGE / "Tests" / "Fixtures"

EXECUTED_RE = re.compile(r"Executed (\d+) tests?, with (\d+) failures?")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fixture_corpus() -> dict:
    """Hash the corpus as a sorted list of (sha256, name) pairs.

    Hashing the concatenation rather than the directory mtime means two checkouts
    with the same fixtures agree, and any changed fixture changes the hash.
    """
    files = sorted(FIXTURES.glob("*.ipa"))
    lines = [f"{sha256_file(path)}  {path.name}\n" for path in files]
    corpus = hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()
    return {
        "directory": FIXTURES.relative_to(ROOT).as_posix(),
        "file_count": len(files),
        "sha256": corpus,
        "files": [path.name for path in files],
    }


def swift_version() -> str | None:
    try:
        completed = subprocess.run(
            ["swift", "--version"],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return None
    output = (completed.stdout or completed.stderr).strip()
    return output.splitlines()[0] if output else None


def parse_log(path: Path) -> dict | None:
    if not path.is_file():
        return None
    text = path.read_text(encoding="utf-8", errors="replace")
    matches = EXECUTED_RE.findall(text)
    executed, failures = matches[-1] if matches else ("0", "0")
    return {
        "log": path.name,
        "executed": int(executed),
        "failures": int(failures),
        "log_sha256": sha256_file(path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", default="sideeditor-core-tests.log")
    parser.add_argument("--output", default="sideeditor-test-manifest.json")
    parser.add_argument("--commit", default=os.environ.get("GITHUB_SHA"))
    parser.add_argument("--run-url", default=None)
    args = parser.parse_args()

    if not FIXTURES.is_dir():
        print(f"fixture directory is missing: {FIXTURES}", file=sys.stderr)
        return 1

    manifest = {
        "schema": 1,
        "generated_from": "scripts/ci/sideeditor_test_manifest.py",
        "commit": args.commit,
        "run_url": args.run_url
        or (
            f"{os.environ['GITHUB_SERVER_URL']}/{os.environ['GITHUB_REPOSITORY']}"
            f"/actions/runs/{os.environ['GITHUB_RUN_ID']}"
            if os.environ.get("GITHUB_RUN_ID")
            else None
        ),
        "platform": {
            "system": platform.system(),
            "machine": platform.machine(),
            "python": platform.python_version(),
        },
        "swift": swift_version(),
        "package": PACKAGE.relative_to(ROOT).as_posix(),
        "fixture_corpus": fixture_corpus(),
        "tests": parse_log(Path(args.log)),
    }

    output = Path(args.output)
    output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
