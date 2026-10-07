from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
source = (root / 'android/src/main/java/com/fugood/screencapture/ScreenCaptureModule.java').read_text()

def method_at(signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

if 'private static ThreadPoolExecutor createEncoder(' in source:
    factory = method_at('    private static ThreadPoolExecutor createEncoder(')
else:
    # Historical initializer with only its Android thread factory made injectable.
    start = source.index('new ThreadPoolExecutor(')
    end = source.index(';', start)
    initializer = source[start:end]
    boundary = initializer.index('work -> new Thread(')
    initializer = initializer[:boundary] + 'factory)'
    factory = ('    private static ThreadPoolExecutor createEncoder(ThreadFactory factory) {\n'
               '        return ' + initializer + ';\n    }')

if 'private void submitEncode(' in source:
    submission = method_at('    private void submitEncode(')
else:
    # Extract the pre-fix production submission block for a meaningful red run.
    start = source.index('        try {\n            encoder.execute(work);')
    end = source.index('    private static Bitmap.CompressFormat compressFormat', start)
    tail = source[start:end].rstrip()
    submission = ('    private void submitEncode(final Bitmap source, final Runnable work, '
                  'final Promise promise) {\n' + tail)

template = (root / 'tests/EncoderSubmission.template').read_text()
output = template.replace('    /* PRODUCTION_FACTORY */', factory)
output = output.replace('    /* PRODUCTION_SUBMISSION */', submission)
out = root / 'tests/out'
out.mkdir(exist_ok=True)
(out / 'EncoderSubmissionTest.java').write_text(output)
(out / 'encoder-source-manifest.json').write_text(json.dumps({
    'factory_sha256': hashlib.sha256(factory.encode()).hexdigest(),
    'submission_sha256': hashlib.sha256(submission.encode()).hexdigest(),
    'scope': 'production factory and submission ownership; JVM API boundaries only',
}, indent=2) + '\n')
