#!/usr/bin/env python3
"""Small extracted-C probes plus explicitly labelled source integration checks.

No UIKit codecs, React callbacks, large allocations, or disk exhaustion are exercised.
Run LeafDeletionProbe.m separately on macOS for the real Foundation substitution case.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument('--source-root', type=Path, default=Path(__file__).resolve().parents[1])
parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parent / 'out/storage-invariants')
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
module = (args.source_root / 'ios/ScreenCapture/ScreenCapture.mm').read_text()
store = (args.source_root / 'ios/ScreenCapture/RNSCFileStore.m').read_text()

def function(source, marker):
    start = source.index(marker)
    body = source.index('{', start)
    end, depth = body + 1, 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

scale = function(module, '- (UIImage *)scaleImage:')
if 'static BOOL RNSCScaledPixelDimensions(' in module:
    dimensions = function(module, 'static BOOL RNSCScaledPixelDimensions(')
else:
    # Execute the original arithmetic byte-for-byte; only the image value and throwing
    # boundary are adapted for C. This catches the pre-rounding cap without allocating pixels.
    body = scale[scale.index('    double width ='):scale.index('    UIGraphicsImageRendererFormat')]
    body = re.sub(r'\[NSException raise:[^;]+;', 'return NO;', body)
    dimensions = '''static BOOL RNSCScaledPixelDimensions(double sourceWidth, double sourceHeight,
        double scale, double *pixelWidth, double *pixelHeight) {
        const ProbeImage image = {{sourceWidth, sourceHeight}, 1};
''' + body + '''
        *pixelWidth = size.width;
        *pixelHeight = size.height;
        return YES;
    }'''

leaf = function(store, 'static int RNSCUnlinkLeafPath(') if 'static int RNSCUnlinkLeafPath(' in store else None
c_source = r'''
#define _XOPEN_SOURCE 700
#include <stdbool.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
typedef bool BOOL;
#define YES true
#define NO false
#define MAX(a,b) ((a) > (b) ? (a) : (b))
typedef struct { double width, height; } CGSize;
typedef struct { CGSize size; double scale; } ProbeImage;
#define CGSizeMake(w,h) ((CGSize){(w),(h)})
''' + dimensions + '\n' + (leaf or '') + r'''
static int failures;
static void check(BOOL condition, const char *name) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", name);
    if (!condition) failures++;
}
int main(void) {
    double width = 0, height = 0;
    check(RNSCScaledPixelDimensions(3000, 2000, .5, &width, &height) &&
          width == 1500 && height == 1000, "ordinary_dimensions");
    check(RNSCScaledPixelDimensions(8, 4, .001, &width, &height) &&
          width == 1 && height == 1, "tiny_dimensions_clamped");
    check(!RNSCScaledPixelDimensions(3000, 2000, 3.2659863237076383, &width, &height),
          "rounded_dimensions_obey_64mp_cap");
    check(!RNSCScaledPixelDimensions(8, 4, INFINITY, &width, &height), "infinite_scale_rejected");
    check(!RNSCScaledPixelDimensions(8, 4, NAN, &width, &height), "nan_scale_rejected");
    LEAF_CHECKS
    return failures ? 1 : 0;
}
'''
if leaf:
    leaf_checks = r'''
    char root[] = "/tmp/rnsc-leaf-probe-XXXXXX";
    if (!mkdtemp(root)) return 2;
    char path[512], sentinel[512];
    snprintf(path, sizeof(path), "%s/capture.png", root);
    snprintf(sentinel, sizeof(sentinel), "%s/capture.png/sentinel", root);
    int fd = open(path, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0 || close(fd) != 0) return 2;
    check(RNSCUnlinkLeafPath(path) == 0, "regular_leaf_removed");
    check(RNSCUnlinkLeafPath(path) == ENOENT, "duplicate_leaf_release_missing");
    if (mkdir(path, 0700) != 0) return 2;
    fd = open(sentinel, O_CREAT | O_EXCL | O_WRONLY, 0600);
    if (fd < 0 || close(fd) != 0) return 2;
    check(RNSCUnlinkLeafPath(path) != 0 && access(sentinel, F_OK) == 0,
          "replacement_directory_and_sentinel_survive");
    if (unlink(sentinel) != 0 || rmdir(path) != 0 || rmdir(root) != 0) return 2;
'''
else:
    leaf_checks = 'check(NO, "file_only_leaf_deletion_integrated");'
c_source = c_source.replace('LEAF_CHECKS', leaf_checks)
c_path = args.output / 'StorageInvariantProbe.c'
c_path.write_text(c_source)
subprocess.run(['clang', '-std=c11', '-Wall', '-Wextra', '-Werror', str(c_path), '-lm',
                '-o', str(args.output / 'StorageInvariantProbe')], check=True)
run = subprocess.run([str(args.output / 'StorageInvariantProbe')], capture_output=True, text=True)
print(run.stdout, end='')
checks = [{'name': line.split(' ', 1)[1], 'passed': line.startswith('PASS '),
           'scope': 'extracted production C / original arithmetic with image/throw adapter'}
          for line in run.stdout.splitlines()]
encode = function(module, '- (void)encodeImage:')
write = function(store, '- (nullable NSString *)writeData:')
release = function(store, '- (BOOL)releaseURI:')
for name, passed in [
    ('encode_has_request_local_autorelease_pool', '@autoreleasepool' in encode),
    ('release_calls_file_only_leaf_helper', bool(leaf) and 'RNSCUnlinkLeafPath(path.fileSystemRepresentation)' in release),
    ('write_failure_cleanup_calls_file_only_leaf_helper', bool(leaf) and 'RNSCUnlinkLeafPath(path.fileSystemRepresentation)' in write),
]:
    print(('PASS ' if passed else 'FAIL ') + name + ' [source integration only]')
    checks.append({'name': name, 'passed': passed, 'scope': 'source integration only; no UIKit pixels'})
report = {'passed': run.returncode == 0 and all(item['passed'] for item in checks),
          'checks': checks, 'source_sha256': {
              'ScreenCapture.mm': hashlib.sha256(module.encode()).hexdigest(),
              'RNSCFileStore.m': hashlib.sha256(store.encode()).hexdigest(),
              'dimensions_extracted_or_adapted': hashlib.sha256(dimensions.encode()).hexdigest(),
              'leaf_extracted': hashlib.sha256((leaf or '').encode()).hexdigest(),
          }}
(args.output / 'results.json').write_text(json.dumps(report, indent=2) + '\n')
raise SystemExit(0 if report['passed'] else 1)
