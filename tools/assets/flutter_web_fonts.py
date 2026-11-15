#!/usr/bin/env python3
"""The gamemaster app in the browser without internet: the fonts Flutter falls
back to for text its own font can't draw (Chinese, Hebrew, Hindi, emoji ... in
players' names) normally come from fonts.gstatic.com. This puts them next to
the app: it reads which ones the build can ask for (main.dart.js), downloads
the missing ones into a cache once (the build PC has internet) and copies them
to <build>/fonts/fallback/ - web/flutter_bootstrap.js points Flutter there
(fontFallbackBaseUrl). ~80 MB; the app only loads the ones a name needs.
    python3 tools/assets/flutter_web_fonts.py gamemaster_app/build/web [--cache out/flutter_fonts]
"""
import argparse, os, re, shutil, sys, urllib.request

CDN = "https://fonts.gstatic.com/s/"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("build", help="the web build (gamemaster_app/build/web)")
    ap.add_argument("--cache", default=os.path.join(os.path.dirname(__file__), "..", "..", "out", "flutter_fonts"))
    a = ap.parse_args()
    js = open(os.path.join(a.build, "main.dart.js"), encoding="utf-8").read()
    fonts = sorted(set(re.findall(r'"([a-z0-9]+/v\d+/[A-Za-z0-9_\-]+\.(?:ttf|otf|woff2?))"', js)))
    if not fonts:
        sys.exit("no fallback fonts found in main.dart.js (another Flutter version?)")
    out = os.path.join(a.build, "fonts", "fallback")
    missing = 0
    for i, f in enumerate(fonts, 1):
        cached = os.path.join(a.cache, f)
        if not os.path.exists(cached):
            os.makedirs(os.path.dirname(cached), exist_ok=True)
            try:
                with urllib.request.urlopen(CDN + f, timeout=60) as r, open(cached + ".part", "wb") as w:
                    shutil.copyfileobj(r, w)
                os.replace(cached + ".part", cached)
                print(f"  [{i}/{len(fonts)}] {f}", flush=True)
            except OSError as e:
                print(f"  missing {f}: {e}", file=sys.stderr)
                missing += 1
                continue
        dest = os.path.join(out, f)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(cached, dest)
    size = sum(os.path.getsize(os.path.join(d, n)) for d, _, ns in os.walk(out) for n in ns)
    print(f"fallback fonts: {len(fonts) - missing} of {len(fonts)} in {out} ({size / 1e6:.0f} MB)")
    sys.exit(1 if missing else 0)


if __name__ == "__main__":
    main()
