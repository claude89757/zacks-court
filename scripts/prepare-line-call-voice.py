#!/usr/bin/env python3
"""Turn a voice take into the line-call clip the app and the browser display play.

The take can come from anywhere (a TTS service's MP3/WAV export, a phone recording); macOS
afconvert decodes it. The script trims leading/trailing silence, normalises the peak, adds short
fades so playback starts and ends without a click, and writes mono 48 kHz AAC to
Sources/CourtCore/Web/voice-out.m4a or voice-in.m4a (the app plays these from the same folder the
browser display is served from; when a file is missing both fall back to speech synthesis).

    scripts/prepare-line-call-voice.py out TAKE.mp3
    scripts/prepare-line-call-voice.py in TAKE.wav --dest /tmp/web
    scripts/prepare-line-call-voice.py --self-test

Record where each take came from (service, voice, date, licence or who recorded it) in
docs/hawk-eye.md when you commit a clip. Standard library plus macOS afconvert only.
"""
import argparse
import array
import math
import os
import subprocess
import sys
import tempfile
import wave

RATE = 48000
DEFAULT_DEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "CourtCore", "Web")
NAMES = {"out": "voice-out.m4a", "in": "voice-in.m4a"}


def afconvert(args):
    subprocess.run(["afconvert", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def read_mono(path, scratch):
    """Decode any afconvert-readable file to 16-bit mono 48 kHz samples."""
    wav = os.path.join(scratch, "decoded.wav")
    afconvert(["-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", path, wav])
    with wave.open(wav, "rb") as f:
        samples = array.array("h", f.readframes(f.getnframes()))
    if sys.byteorder == "big":
        samples.byteswap()
    return samples


def process(samples, threshold_db=-40.0, peak_db=-1.0, pad_ms=15, fade_ms=8):
    """Trim silence (with a little padding), normalise the peak and fade both ends."""
    if not samples:
        raise ValueError("the take is empty")
    loudest = max(abs(s) for s in samples)
    if loudest == 0:
        raise ValueError("the take is silent")
    gate = loudest * 10 ** (threshold_db / 20)
    voiced = [i for i, s in enumerate(samples) if abs(s) >= gate]
    pad = RATE * pad_ms // 1000
    start, end = max(0, voiced[0] - pad), min(len(samples), voiced[-1] + 1 + pad)
    gain = 32767 * 10 ** (peak_db / 20) / loudest
    clip = [samples[i] * gain for i in range(start, end)]
    fade = min(RATE * fade_ms // 1000, len(clip) // 2)
    for i in range(fade):
        k = i / fade
        clip[i] *= k
        clip[-1 - i] *= k
    return array.array("h", (max(-32768, min(32767, round(v))) for v in clip))


def write_m4a(samples, path, scratch):
    wav = os.path.join(scratch, "clip.wav")
    data = samples
    if sys.byteorder == "big":
        data = array.array("h", samples)
        data.byteswap()
    with wave.open(wav, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(data.tobytes())
    afconvert(["-f", "m4af", "-d", "aac", "-b", "96000", wav, path])


def describe(samples):
    peak = max(abs(s) for s in samples) or 1
    return f"{len(samples) / RATE * 1000:.0f} ms, peak {20 * math.log10(peak / 32768):.1f} dBFS"


def self_test():
    # 100 ms silence, 300 ms tone at -20 dBFS, 200 ms silence.
    tone = [round(3277 * math.sin(2 * math.pi * 440 * i / RATE)) for i in range(RATE * 3 // 10)]
    take = array.array("h", [0] * (RATE // 10) + tone + [0] * (RATE // 5))
    clip = process(take)
    ms = len(clip) / RATE * 1000
    assert 300 <= ms <= 335, ms
    peak = 20 * math.log10(max(abs(s) for s in clip) / 32768)
    assert -1.3 <= peak <= -0.9, peak
    assert clip[0] == 0 and clip[-1] == 0
    with tempfile.TemporaryDirectory() as scratch:
        out = os.path.join(scratch, "voice-out.m4a")
        write_m4a(clip, out, scratch)
        back = read_mono(out, scratch)
        assert abs(len(back) - len(clip)) < RATE // 20, (len(back), len(clip))
    print(f"self-test ok ({describe(clip)})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("call", nargs="?", choices=sorted(NAMES))
    parser.add_argument("take", nargs="?")
    parser.add_argument("--dest", default=DEFAULT_DEST, help="folder to write the clip into")
    parser.add_argument("--threshold-db", type=float, default=-40.0, help="silence gate relative to the peak")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not args.call or not args.take:
        parser.error("give the call (out or in) and the take file")
    with tempfile.TemporaryDirectory() as scratch:
        take = read_mono(args.take, scratch)
        clip = process(take, threshold_db=args.threshold_db)
        out = os.path.join(os.path.abspath(args.dest), NAMES[args.call])
        write_m4a(clip, out, scratch)
    print(f"{out}: {describe(clip)} (take {describe(take)})")


if __name__ == "__main__":
    main()
