#!/usr/bin/env bash
# Lists every localizable text of the app (as the Swift compiler sees it) that has no
# German translation in Resources/de.lproj/Localizable.strings, and German entries whose
# format specifiers don't match their key. Exits 1 if anything is missing.
#
#   scripts/check-localization.sh
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
# A full compile of the Hearth target, so every file reports its strings.
rm -rf .build/*/debug/Hearth.build
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null 2>&1
python3 - "$OUT" <<'PY'
import sys, json, glob, os, re, subprocess
out = sys.argv[1]
sources = {os.path.basename(p).replace('.swift', '') for p in glob.glob('Sources/Hearth/**/*.swift', recursive=True)}
keys = {}
for f in glob.glob(f'{out}/*.stringsdata'):
    if os.path.basename(f).replace('.stringsdata', '') not in sources: continue
    for e in json.load(open(f))['tables'].get('Localizable', []):
        keys.setdefault(e['key'], os.path.basename(f).replace('.stringsdata', '.swift') + ':' + str(e['location']['startingLine']))
data = subprocess.run(['plutil', '-convert', 'json', '-o', '-', 'Resources/de.lproj/Localizable.strings'], capture_output=True, check=True).stdout
german = json.loads(data)
spec = re.compile(r'%(?:\d+\$)?(?:lld|llu|ld|lf|@|d|f|u)')
norm = lambda s: sorted(re.sub(r'\d+\$', '', x) for x in spec.findall(s.replace('%%', '')))
missing = [k for k in keys if k not in german and re.search(r'[A-Za-z]{2,}', re.sub(spec, '', k))]
broken = [k for k, v in german.items() if norm(k) != norm(v)]
for k in sorted(missing): print(f'missing  {keys[k]}  {k!r}')
for k in sorted(broken): print(f'format   {k!r} -> {german[k]!r}')
print(f'{len(keys)} keys, {len(missing)} without German, {len(broken)} with mismatched placeholders')
sys.exit(1 if missing or broken else 0)
PY
