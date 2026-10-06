#!/usr/bin/env python3
"""Byte-exact production methods; UIKit/React codec boundaries are labelled stubs in the CLI."""
from pathlib import Path
import hashlib, json
root = Path(__file__).resolve().parents[1]
out = root / 'tests/out'
out.mkdir(exist_ok=True)
module = (root / 'ios/ScreenCapture/ScreenCapture.mm').read_text()
window = (root / 'ios/ScreenCapture/RNSCWindowCapture.m').read_text()
def method(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]
excerpts = {
    'EncodeCurrent.inc': method(module, '- (void)encodeImage:', '\n- (BOOL)isInvalidated'),
    'SerialCurrent.inc': method(window, '+ (void)performSerially:', '+ (UIWindow *)primaryWindowForWindows:'),
    'PrimaryCurrent.inc': method(window, '+ (UIWindow *)primaryWindowForWindows:', '+ (void)captureNowExcludingStatusBar:'),
    'WaitCurrent.inc': method(window, '+ (NSHashTable<id<RNSCFrameProvider>> *)hopelessProviders', '+ (nullable UIImage *)renderWindows:'),
}
for name in ['Player', 'Camera', 'SampleBuffer']:
    source = (root / f'ios/ScreenCapture/RNSC{name}FrameProvider.m').read_text()
    start = source.index('- (CGImageRef _Nullable)newFrameImage')
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    excerpts[f'Frame{name}.inc'] = source[start:end] + '\n'
for name, source in excerpts.items(): (out / name).write_text(source)
(out / 'native-source-manifest.json').write_text(json.dumps({
    name: hashlib.sha256(source.encode()).hexdigest() for name, source in excerpts.items()
}, indent=2) + '\n')
