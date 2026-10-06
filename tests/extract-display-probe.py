from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
source = (root / 'android/src/main/java/com/fugood/screencapture/ScreenCaptureAccessibilityService.java').read_text()
start = source.index('    private static void captureDisplays(')
end = source.index('    /** Side by side', start)
excerpt = source[start:end]
template = (root / 'tests/DisplayContinuation.template').read_text()
out = root / 'tests/out'
out.mkdir(exist_ok=True)
(out / 'DisplayContinuationTest.java').write_text(
    template.replace('    /* PRODUCTION_SEQUENCE */', excerpt))
(out / 'display-source-manifest.json').write_text(json.dumps({
    'sequence_sha256': hashlib.sha256(excerpt.encode()).hexdigest(),
    'scope': 'production display continuation; deterministic bitmap/request/stitch boundaries',
}, indent=2) + '\n')
