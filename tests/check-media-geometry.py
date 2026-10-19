#!/usr/bin/env python3
"""Check raw 2x PNG output of the documented physical media geometry fixture."""
import argparse
from pathlib import Path

from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("images", type=Path)
parser.add_argument("--media-sublayer", action="store_true")
args = parser.parse_args()

# Expected colors come from the fixture's UI, independent of capture internals:
# cyan control at local (20,20,60,30), red/green background quadrants,
# host frame (80,160,400,240), seven styles with two captures each.
controls = {0: (110, 190), 1: (370, 110), 3: (110, 190),
            4: (110, 190), 5: (170, 154), 6: (110, 190)}
failures = []
for sequence in range(1, 15):
    image = Image.open(args.images / f"{sequence:03}-library.png").convert("RGB")
    assert image.size == (828, 1792), "Fixture requires the physical XR's 2x output"
    if all(high <= 1 for low, high in image.getextrema()):
        failures.append(f"{sequence}: whole-black image")
    style = (sequence - 1) // 2
    samples = []
    if style in controls:
        point = (110, 190) if args.media_sublayer else controls[style]
        color = (153, 102, 102) if style == 4 and not args.media_sublayer else (0, 255, 255)
        samples.append(("control", point, color))
    if style == 3:
        samples.append(("outside rounded corner", (90, 390), (255, 0, 0)))
    if style == 6:
        samples.append(("outside triangle mask", (380, 340), (0, 255, 0)))
    for label, (x, y), expected in samples:
        actual = image.getpixel((x * 2, y * 2))
        if actual != expected:
            failures.append(f"{sequence} {label}: expected {expected}, got {actual}")
if failures:
    raise SystemExit("\n".join(failures))
print("PASS: 14 raw images, native clipping/opacity and control ordering")
