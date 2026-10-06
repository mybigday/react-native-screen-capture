#!/usr/bin/env python3
"""Run extracted provider lifecycle methods, with labelled AVFoundation boundary doubles.

--native compiles byte-exact Objective-C excerpts against Foundation/CoreVideo on macOS.
--portable (default) mechanically adapts those same excerpts to C++ on Linux. The
portable adapter preserves branches/exception paths; its framework objects and buffer
counter are doubles. It is not an Apple runtime, weak-reference, concurrency or pixel test.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def extract(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end] + "\n"


def closing(text, opening):
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return end


def finally_blocks(text):
    # RAII is the portable equivalent for these cleanup blocks. The fixture's cleanup
    # operations do not throw during exception unwinding; native mode covers Obj-C itself.
    while "@finally" in text:
        marker = text.index("@finally")
        previous_end = marker - 1
        while text[previous_end].isspace():
            previous_end -= 1
        assert text[previous_end] == "}"
        depth, previous_start = 1, previous_end - 1
        while depth:
            depth += (text[previous_start] == "}") - (text[previous_start] == "{")
            previous_start -= 1
        previous_start += 1
        try_marker = text.rfind("@try", 0, previous_start)
        assert text[try_marker:previous_start].strip() == "@try"
        cleanup_start = text.index("{", marker)
        cleanup_end = closing(text, cleanup_start)
        body = text[previous_start + 1:previous_end]
        cleanup = text[cleanup_start + 1:cleanup_end - 1]
        text = (text[:try_marker] + "{ auto cleanup = onExit([&]() {" + cleanup
                + "}); " + body + " }" + text[cleanup_end:])
    return text


def portable(method):
    signature, body = method.split("{", 1)
    name = re.search(r"\)(\w+)\s*$", signature.strip()).group(1)
    result = re.search(r"- \(([^)]+)\)", signature).group(1)
    text = result + " " + name + "() {" + body
    text = re.sub(r"//[^\n]*", "", text)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    # Attribute dictionary contents are an AVFoundation configuration boundary, not
    # lifecycle behavior under test. The native fixture receives the real dictionary.
    while "@{" in text:
        start = text.index("@{")
        end = closing(text, start + 1)
        text = text[:start] + "0" + text[end:]
    text = re.sub(r"id<[^>]+>", "Delegate *", text)
    text = text.replace("AVCaptureVideoDataOutput.class", "OutputClass")
    text = text.replace("AVCaptureVideoDataOutput", "Output").replace("AVCaptureOutput", "Output")
    text = text.replace("AVCaptureSession", "Session").replace("AVPlayerItem", "Item")
    text = text.replace("NSException", "Exception")
    text = re.sub(r"for \(Output \*output in session\.outputs\)",
                  "for (Output *output : session->outputs->values)", text)
    # Property access is a labelled fixture boundary. nil delegate reads retain Obj-C semantics.
    for receiver in ["active", "existing", "borrowed"]:
        text = text.replace(receiver + ".sampleBufferDelegate", "delegateOf(" + receiver + ")")
    text = re.sub(r"(session|_session|item)\.outputs", r"\1->outputs", text)
    text = re.sub(r"(output|existing)\.(\w+)", r"\1->\2", text)
    while "[" in text:
        start = text.rfind("[")
        end = text.index("]", start)
        message = text[start + 1:end].strip()
        receiver, selector = message.split(None, 1)
        receiver = "this" if receiver == "self" else receiver
        pieces = re.findall(r"(\w+):\s*(.*?)(?=\s+\w+:|$)", selector)
        if pieces:
            call = pieces[0][0] + "(" + ", ".join(arg.strip() for _, arg in pieces) + ")"
        else:
            call = selector + "()"
        operator = "::" if receiver == "Output" else "->"
        text = text[:start] + receiver + operator + call + text[end + 1:]
    text = finally_blocks(text)
    text = text.replace("@try", "try").replace("@catch", "catch").replace("@throw", "throw")
    text = re.sub(r"\bYES\b", "true", text)
    text = re.sub(r"\bNO\b", "false", text)
    text = re.sub(r"\bnil\b", "nullptr", text)
    text = re.sub(r"\bself\b", "this", text)
    if "@" in text:
        raise ValueError("Untranslated Objective-C syntax in " + name)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true")
    args = parser.parse_args()
    camera = (ROOT / "ios/ScreenCapture/RNSCCameraFrameProvider.m").read_text()
    player = (ROOT / "ios/ScreenCapture/RNSCPlayerFrameProvider.m").read_text()
    camera_methods = [extract(camera, signature) for signature in
                      ["- (void)attach\n", "- (void)detach\n", "- (NSUInteger)attachmentGeneration"]]
    player_methods = [extract(player, signature) for signature in
                      ["- (void)detach\n", "- (void)detachOutputFromObservedItem\n"]]
    manifest = {"camera": hashlib.sha256("".join(camera_methods).encode()).hexdigest(),
                "player": hashlib.sha256("".join(player_methods).encode()).hexdigest()}
    with tempfile.TemporaryDirectory(prefix="rnsc-provider-lifecycle-") as temporary:
        out = Path(temporary)
        adapter = (lambda x: x) if args.native else portable
        (out / "CameraLifecycle.inc").write_text("\n".join(map(adapter, camera_methods)))
        (out / "PlayerLifecycle.inc").write_text("\n".join(map(adapter, player_methods)))
        executable = out / "probe"
        if args.native:
            command = ["xcrun", "clang", "-fobjc-arc", "-fblocks", "-framework", "Foundation",
                       "-framework", "CoreVideo", "-I" + str(out),
                       str(ROOT / "tests/ProviderLifecycleProbe.m"), "-o", str(executable)]
        else:
            command = ["clang++", "-std=c++17", "-Wall", "-Wextra", "-Werror",
                       "-I" + str(out), str(ROOT / "tests/ProviderLifecycleProbe.cpp"),
                       "-o", str(executable)]
        subprocess.run(command, check=True)
        completed = subprocess.run([str(executable)], text=True, capture_output=True)
        print(json.dumps({"scope": "byte-exact Objective-C, Foundation/CoreVideo, AV doubles" if args.native
                          else "extracted production methods mechanically adapted to C++, AV/buffer doubles",
                          "source_sha256": manifest, "exit_code": completed.returncode,
                          "results": completed.stdout.strip(), "failure": completed.stderr.strip()}, indent=2))
        raise SystemExit(completed.returncode)


if __name__ == "__main__":
    main()
