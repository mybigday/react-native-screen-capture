from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[1]
path = Path(sys.argv[1]) if len(sys.argv) > 1 else root / 'android/src/main/java/com/fugood/screencapture/WindowCapture.java'
source = path.read_text()

names = ['static CaptureCallback once(', 'static void captureOnUiThread(',
         'static void copySurfaceViews(', 'static void captureWindow(',
         'static void removeOverlays(', 'static void collectSurfaceViews(']
if 'static PixelCopyBudget.Lease[] reserveSurfaceCopies(' in source:
    names.append('static PixelCopyBudget.Lease[] reserveSurfaceCopies(')
for name in ['static void removeOverlay(', 'static void recycleBitmap(']:
    if name in source:
        names.append(name)
excerpts = []
for name in names:
    start = source.rfind('\n', 0, source.index(name)) + 1
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        if source[end] == '{': depth += 1
        if source[end] == '}': depth -= 1
        end += 1
    excerpts.append(source[start:end])
excerpt = '\n\n'.join(excerpts)
out = root / 'tests/out'
out.mkdir(exist_ok=True)
(out / 'PixelCopyBudgetTest.java').write_text((root / 'tests/PixelCopyBudget.template').read_text().replace('    /* PRODUCTION_METHODS */', excerpt))
(out / 'pixelcopy-source-manifest.json').write_text(json.dumps({
    'source': str(path), 'methods': names,
    'methods_sha256': hashlib.sha256(excerpt.encode()).hexdigest(),
    'scope': 'byte-exact production methods; fake Android PixelCopy, bitmap, view and clock boundaries',
}, indent=2) + '\n')
