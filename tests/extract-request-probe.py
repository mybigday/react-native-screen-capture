from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parents[1]
source = (root / 'android/src/main/java/com/fugood/screencapture/ScreenCaptureAccessibilityService.java').read_text()
start = source.index('    @RequiresApi(Build.VERSION_CODES.R)\n    private static final class ScreenshotRequest')
end = source.index('    @RequiresApi(Build.VERSION_CODES.R)\n    private static String describeError', start)
excerpt = source[start:end]
template = (root / 'tests/RequestControlFlow.template').read_text()
out = root / 'tests/out'
out.mkdir(exist_ok=True)
(out / 'RequestControlFlowTest.java').write_text(template.replace('    /* PRODUCTION_REQUEST */', excerpt))
(out / 'request-source-manifest.json').write_text(json.dumps({'excerpt_sha256': hashlib.sha256(excerpt.encode()).hexdigest()}, indent=2) + '\n')
