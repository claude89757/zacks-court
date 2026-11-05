#!/usr/bin/env python3
"""Turn a voice take into a line-call clip the app and the browser display play.

The take can come from anywhere (scripts/generate-line-call-voices.py, another TTS export, a phone
recording); macOS afconvert decodes it. The script trims leading/trailing silence, makes the call
loud and even across voices (the loudest 50 ms is brought to -9 dBFS RMS, then a look-ahead limiter
holds peaks at -1 dBFS), adds short fades so playback starts and ends without a click, and writes
mono 48 kHz AAC to Sources/CourtCore/Web/voice-<voice>-<call>.m4a. Voices are listed in
Sources/CourtCore/LineCallVoice.swift and Web/app.js (VOICES); when a clip is missing the app and the
page fall back to speech synthesis.

    scripts/prepare-line-call-voice.py ash out TAKE.wav
    scripts/prepare-line-call-voice.py coral in TAKE.mp3 --dest /tmp/web
    scripts/prepare-line-call-voice.py --self-test

Record where each take came from in docs/hawk-eye.md when you commit clips. Standard library plus
macOS afconvert only.
"""
import argparse
import array
import collections
import math
import os
import re
import subprocess
import sys
import tempfile
import wave

RATE = 48000
DEFAULT_DEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "CourtCore", "Web")
CALLS = ("out", "in")


def afconvert(args):
    subprocess.run(["afconvert", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)


def read_mono(path, scratch):
    """Decode any afconvert-readable file to mono 48 kHz floats in [-1, 1]."""
    wav = os.path.join(scratch, "decoded.wav")
    afconvert(["-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", path, wav])
    with wave.open(wav, "rb") as f:
        samples = array.array("h", f.readframes(f.getnframes()))
    if sys.byteorder == "big":
        samples.byteswap()
    return [s / 32768 for s in samples]


def db(x):
    return 20 * math.log10(max(x, 1e-9))


def trim(x, threshold_db, pad_ms=15):
    loudest = max(abs(v) for v in x)
    if loudest == 0:
        raise ValueError("the take is silent")
    gate = loudest * 10 ** (threshold_db / 20)
    voiced = [i for i, v in enumerate(x) if abs(v) >= gate]
    pad = RATE * pad_ms // 1000
    return x[max(0, voiced[0] - pad):min(len(x), voiced[-1] + 1 + pad)]


def loudest_rms(x, window_ms=50):
    n = max(1, min(len(x), RATE * window_ms // 1000))
    total = sum(v * v for v in x[:n])
    best = total
    for i in range(n, len(x)):
        total += x[i] * x[i] - x[i - n] * x[i - n]
        best = max(best, total)
    return math.sqrt(max(best, 0) / n)


def sliding_min(values, half):
    """min(values[i-half .. i+half]) for every i, in linear time."""
    out, window = [0.0] * len(values), collections.deque()
    for j in range(len(values) + half):
        if j < len(values):
            while window and values[window[-1]] >= values[j]:
                window.pop()
            window.append(j)
        i = j - half
        if i >= 0:
            while window[0] < i - half:
                window.popleft()
            out[i] = values[window[0]]
    return out


def limit(x, ceiling_db=-1.0, lookahead_ms=5, release_ms=80):
    """Look-ahead peak limiter: gain never exceeds what keeps every sample under the ceiling."""
    ceiling = 10 ** (ceiling_db / 20)
    need = [min(1.0, ceiling / abs(v)) if v else 1.0 for v in x]
    look = max(1, RATE * lookahead_ms // 1000)
    envelope = sliding_min(need, look)
    # A centred moving average over half the look-ahead stays under `need` (every term covers the peak)
    # and turns the gain change into a ramp instead of a step.
    half = look // 2
    prefix = [0.0]
    for v in envelope:
        prefix.append(prefix[-1] + v)
    smooth = []
    for i in range(len(envelope)):
        a, b = max(0, i - half), min(len(envelope), i + half + 1)
        smooth.append((prefix[b] - prefix[a]) / (b - a))
    recover = 1 - math.exp(-1 / (RATE * release_ms / 1000))
    gain, out = 1.0, []
    for v, g in zip(x, smooth):
        gain = min(g, gain + (1 - gain) * recover)
        out.append(max(-ceiling, min(ceiling, v * gain)))
    return out


def process(x, threshold_db=-40.0, loudness_db=-9.0, ceiling_db=-1.0, max_reduction_db=10.0, fade_ms=8):
    if not x:
        raise ValueError("the take is empty")
    trimmed = trim(x, threshold_db)
    peak = max(abs(v) for v in trimmed)
    if db(peak) < -40:
        # A failed take (no speech): raising it to the target would only amplify noise.
        raise ValueError(f"the take is nearly silent (peak {db(peak):.1f} dBFS)")
    # Limiting a peaky take pulls its loudness down again, so the gain is raised until the loudest 50 ms
    # sits at the target, but never so far that the limiter takes more than max_reduction_db off a peak.
    most = 10 ** ((ceiling_db + max_reduction_db) / 20) / peak
    gain = min(most, 10 ** (loudness_db / 20) / max(loudest_rms(trimmed), 1e-9))
    for _ in range(6):
        clip = limit([v * gain for v in trimmed], ceiling_db)
        miss = loudness_db - db(loudest_rms(clip))
        if abs(miss) < 0.2 or gain >= most:
            break
        gain = min(most, gain * 10 ** (miss / 20))
    fade = min(RATE * fade_ms // 1000, len(clip) // 2)
    for i in range(fade):
        k = i / fade
        clip[i] *= k
        clip[-1 - i] *= k
    return clip


def write_m4a(x, path, scratch):
    wav = os.path.join(scratch, "clip.wav")
    data = array.array("h", (max(-32768, min(32767, round(v * 32767))) for v in x))
    if sys.byteorder == "big":
        data.byteswap()
    with wave.open(wav, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(data.tobytes())
    afconvert(["-f", "m4af", "-d", "aac", "-b", "96000", wav, path])


def describe(x):
    return f"{len(x) / RATE * 1000:.0f} ms, peak {db(max(abs(v) for v in x)):.1f} dBFS, loudest 50 ms {db(loudest_rms(x)):.1f} dBFS RMS"


def self_test():
    sine = lambda amp, ms: [amp * math.sin(2 * math.pi * 440 * i / RATE) for i in range(RATE * ms // 1000)]
    silence = lambda ms: [0.0] * (RATE * ms // 1000)
    # A quiet tone is trimmed and brought up to -9 dBFS RMS (a sine's peak is 3 dB above its RMS).
    clip = process(silence(100) + sine(0.1, 300) + silence(200))
    assert 300 <= len(clip) / RATE * 1000 <= 335, len(clip)
    assert abs(db(loudest_rms(clip)) + 9) < 0.3, db(loudest_rms(clip))
    assert abs(db(max(abs(v) for v in clip)) + 6) < 0.3
    assert clip[0] == 0 and clip[-1] == 0
    # A spike on the tone is held at the ceiling; the limiter lets go again within a few release times.
    take = sine(0.1, 800)
    take[RATE // 10] = 0.5
    clip = process(take)
    assert db(max(abs(v) for v in clip)) <= -0.99
    assert abs(db(loudest_rms(clip[RATE // 2:])) + 9) < 0.5, db(loudest_rms(clip[RATE // 2:]))
    # A spike that would need more than 10 dB of limiting caps the gain instead of crushing the take.
    take[RATE // 10] = 1.0
    clip = process(take)
    assert abs(db(loudest_rms(clip[RATE // 2:])) + 14) < 0.5, db(loudest_rms(clip[RATE // 2:]))
    with tempfile.TemporaryDirectory() as scratch:
        out = os.path.join(scratch, "voice-test-out.m4a")
        write_m4a(clip, out, scratch)
        back = read_mono(out, scratch)
        assert abs(len(back) - len(clip)) < RATE // 20, (len(back), len(clip))
    print(f"self-test ok ({describe(clip)})")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("voice", nargs="?", help="voice id, e.g. ash")
    parser.add_argument("call", nargs="?", choices=CALLS)
    parser.add_argument("take", nargs="?")
    parser.add_argument("--dest", default=DEFAULT_DEST, help="folder to write the clip into")
    parser.add_argument("--threshold-db", type=float, default=-40.0, help="silence gate relative to the peak")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not (args.voice and args.call and args.take):
        parser.error("give the voice, the call (out or in) and the take file")
    if not re.fullmatch(r"[a-z]+", args.voice):
        parser.error("the voice id is lower-case letters")
    with tempfile.TemporaryDirectory() as scratch:
        take = read_mono(args.take, scratch)
        clip = process(take, threshold_db=args.threshold_db)
        out = os.path.join(os.path.abspath(args.dest), f"voice-{args.voice}-{args.call}.m4a")
        write_m4a(clip, out, scratch)
    print(f"{out}: {describe(clip)} (take {describe(take)})")


if __name__ == "__main__":
    main()
