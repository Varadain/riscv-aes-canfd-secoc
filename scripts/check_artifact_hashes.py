import argparse
import hashlib
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "SHA256SUMS.json"


def current_hashes():
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT, check=True, capture_output=True,
    )
    names = sorted(set(result.stdout.decode("utf-8").split("\0")) - {"", MANIFEST.name})
    return {name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest() for name in names}


def main():
    parser = argparse.ArgumentParser(description="Check or regenerate the public artifact SHA-256 manifest.")
    parser.add_argument("--write", action="store_true", help="Regenerate after an intentional artifact update.")
    args = parser.parse_args()
    actual = current_hashes()
    if args.write:
        MANIFEST.write_text(json.dumps(actual, indent=2) + "\n", encoding="utf-8")
        print(f"Wrote SHA-256 hashes for {len(actual)} files.")
        return
    expected = json.loads(MANIFEST.read_text(encoding="utf-8"))
    if actual != expected:
        missing = sorted(expected.keys() - actual.keys())
        extra = sorted(actual.keys() - expected.keys())
        changed = sorted(name for name in actual.keys() & expected.keys() if actual[name] != expected[name])
        raise SystemExit(f"FAIL: missing={missing}, extra={extra}, changed={changed}")
    print(f"PASS: {len(actual)} public artifact files match their SHA-256 hashes.")


if __name__ == "__main__":
    main()
