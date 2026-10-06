from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
source = (root / 'android/src/main/java/com/fugood/screencapture/ScreenCapturetListenManager.java').read_text()
if '    private static void closeCursor(' in source:
    start = source.index('    private static void closeCursor(')
    end = source.index('    private Point getImageSize(', start)
    excerpt = source[start:end]
else:
    start = source.index('        } finally {', source.index('    private void handleMediaContentChange('))
    end = source.index('    private Point getImageSize(', start)
    tail = source[start:end]
    body = tail[tail.index('\n') + 1:tail.rindex('\n        }')]
    excerpt = '    private static void closeCursor(Cursor cursor) {\n' + body + '\n    }\n'
template = (root / 'tests/ObserverCursor.template').read_text()
out = root / 'tests/out'
out.mkdir(exist_ok=True)
(out / 'ObserverCursorTest.java').write_text(template.replace('    /* PRODUCTION_CURSOR_CLOSE */', excerpt))
(out / 'observer-cursor-source-manifest.json').write_text(json.dumps({
    'close_sha256': hashlib.sha256(excerpt.encode()).hexdigest(),
    'scope': 'production observer cursor cleanup; deterministic cursor boundary',
}, indent=2) + '\n')
