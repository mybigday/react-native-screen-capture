#!/usr/bin/env python3
"""Byte-exact production camera methods; Foundation/CoreMedia/CoreVideo with AV doubles.
No camera inputs, device access, private APIs or running capture sessions.
"""
from pathlib import Path
import hashlib
import json
import re
import runpy
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
extract = runpy.run_path(str(ROOT / 'tests/provider-lifecycle.py'))['extract']
source = (ROOT / 'ios/ScreenCapture/RNSCCameraFrameProvider.m').read_text()
registry = (ROOT / 'ios/ScreenCapture/RNSCProviderRegistry.m').read_text()
store = re.search(r'\[self->_cameraSources setObject:source forKey:[^\]]+\];', registry).group(0)
methods = '\n'.join(extract(source, signature) for signature in [
    '- (nullable instancetype)initWithPreviewLayer:',
    '- (void)attach\n', '- (void)detach\n', '- (NSUInteger)attachmentGeneration',
    '- (BOOL)hasFrame\n', '- (nullable id<AVCaptureVideoDataOutputSampleBufferDelegate>)borrowedDelegate',
    '- (void)captureOutput:(AVCaptureOutput *)output\n    didOutputSampleBuffer:'])
helpers = ''
if 'static NSString *RNSCVideoStreamIdentity' in source:
    helpers = extract(source, 'static NSString *RNSCVideoStreamIdentity')
    for signature in ['+ (NSString *)sourceIdentifierForPreview:', '- (BOOL)matchesPreview:',
                      '- (BOOL)matchesConnection:', '- (BOOL)matchesOutput:', '- (BOOL)canCreateOutput']:
        methods += '\n' + extract(source, signature)
with tempfile.TemporaryDirectory(prefix='rnsc-camera-streams-') as temporary:
    out = Path(temporary)
    (out / 'CameraStreamMethods.inc').write_text(methods)
    (out / 'CameraStreamHelpers.inc').write_text(helpers)
    (out / 'CameraSourceStore.inc').write_text(store)
    command = ['xcrun', 'clang', '-fobjc-arc', '-fblocks', '-framework', 'Foundation',
               '-framework', 'CoreVideo', '-framework', 'CoreMedia',
               '-I' + str(out), '-DRNSC_HAS_STREAM_HELPERS=' + str(int(bool(helpers))),
               str(ROOT / 'tests/CameraStreamProbe.m'), '-o', str(out / 'probe')]
    subprocess.run(command, check=True)
    result = subprocess.run([str(out / 'probe')], text=True, capture_output=True)
    print(json.dumps({'scope': 'byte-exact production selection/publication, AV doubles, real CoreVideo samples',
                      'source_sha256': hashlib.sha256((helpers + methods + store).encode()).hexdigest(),
                      'exit_code': result.returncode, 'results': result.stdout.strip(),
                      'failure': result.stderr.strip()}, indent=2))
    raise SystemExit(result.returncode)
