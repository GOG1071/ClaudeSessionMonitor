"""Build the zip that Decky Loader installs (Settings > Developer > Install plugin from ZIP).

Run `npm run build` first; this only bundles the already-built files.
"""
import os
import sys
import zipfile

ROOT = os.path.dirname(os.path.abspath(__file__))
FOLDER = "claude-session-monitor"
FILES = ["plugin.json", "package.json", "main.py", "dist/index.js", "py_modules/herdr_monitor.py"]


def main():
    if not os.path.exists(os.path.join(ROOT, "dist", "index.js")):
        sys.exit("dist/index.js missing: run `npm run build` first")
    out_dir = os.path.join(ROOT, "out")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, f"{FOLDER}.zip")
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
        for rel in FILES:
            zf.write(os.path.join(ROOT, rel), f"{FOLDER}/{rel}")
    print(out)


if __name__ == "__main__":
    main()
