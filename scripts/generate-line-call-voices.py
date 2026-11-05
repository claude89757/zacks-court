#!/usr/bin/env python3
"""Generate the line-call voices ("Out!" / "In.") with the OpenAI speech API.

For every voice in Sources/CourtCore/LineCallVoice.swift and both calls, asks gpt-4o-mini-tts for a
few takes (WAV) with the line-judge instructions below, keeps them in .local/line-call-takes/, and
turns the chosen take into Sources/CourtCore/Web/voice-<voice>-<call>.m4a with
scripts/prepare-line-call-voice.py. Listen to the results before committing; swap a take with
--only VOICE-CALL --pick N (no new request when the takes are already there).

    scripts/generate-line-call-voices.py                       # all voices, 3 takes each, use take 1
    scripts/generate-line-call-voices.py --only coral-in --pick 2
    scripts/generate-line-call-voices.py --only ash-out --regenerate

The API key comes from OPENAI_API_KEY or a line OPENAI_API_KEY=... in .local/openai.env (this
checkout's, or the main checkout's when run in a git worktree). It is never printed. OpenAI's usage
policies require telling listeners the voice is AI-generated: the app and the browser display say so
next to the voice picker. Standard library only.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
CATALOG = os.path.join(ROOT, "Sources", "CourtCore", "LineCallVoice.swift")
PREPARE = os.path.join(ROOT, "scripts", "prepare-line-call-voice.py")
MODEL = "gpt-4o-mini-tts"
WORDS = {"out": "Out!", "in": "In."}
INSTRUCTIONS = (
    "Voice: A {gender} professional tennis line judge at a packed stadium.\n\n"
    "Delivery: Shout at full volume, as loud as you can, projecting over a cheering crowd to the far side "
    "of the court. One sharp, explosive, decisive call. Short and clipped, with a falling pitch at the end. "
    "No hesitation, no breath before it, no extra words.\n\n"
    "Tone: Authoritative, confident and crisp, like an official making a final call."
)


def voices():
    text = open(CATALOG, encoding="utf-8").read()
    found = re.findall(r'LineCallVoice\(id: "([a-z]+)", name: "[^"]+", gender: \.(male|female)\)', text)
    if not found:
        sys.exit(f"no voices found in {CATALOG}")
    return found


def api_key():
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"].strip()
    candidates = [os.path.join(ROOT, ".local", "openai.env")]
    try:
        common = subprocess.run(["git", "-C", ROOT, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                check=True, capture_output=True, text=True).stdout.strip()
        candidates.append(os.path.join(os.path.dirname(common), ".local", "openai.env"))
    except (OSError, subprocess.CalledProcessError):
        pass
    for path in candidates:
        if os.path.isfile(path):
            for line in open(path, encoding="utf-8"):
                key, _, value = line.strip().partition("=")
                if key.strip() in ("OPENAI_API_KEY", "export OPENAI_API_KEY") and value.strip():
                    return value.strip().strip("'\"")
    sys.exit("no API key: set OPENAI_API_KEY or put OPENAI_API_KEY=... in .local/openai.env")


def speak(key, voice, gender, call, path):
    body = json.dumps({"model": MODEL, "voice": voice, "input": WORDS[call],
                       "instructions": INSTRUCTIONS.format(gender=gender), "response_format": "wav"}).encode()
    request = urllib.request.Request("https://api.openai.com/v1/audio/speech", data=body, method="POST",
                                     headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:300]
        raise SystemExit(f"{voice}-{call}: HTTP {error.code} {detail}")
    if data[:4] != b"RIFF":
        raise SystemExit(f"{voice}-{call}: the API did not return WAV audio")
    with open(path, "wb") as f:
        f.write(data)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", help="comma-separated VOICE-CALL or VOICE, e.g. ash-out,coral")
    parser.add_argument("--takes", type=int, default=3, help="takes to keep per voice and call")
    parser.add_argument("--pick", type=int, default=1, help="which take becomes the clip")
    parser.add_argument("--regenerate", action="store_true", help="request new takes even if some exist")
    parser.add_argument("--takes-dir", default=os.path.join(ROOT, ".local", "line-call-takes"))
    parser.add_argument("--dest", default=os.path.join(ROOT, "Sources", "CourtCore", "Web"))
    args = parser.parse_args()
    if not 1 <= args.pick <= args.takes:
        parser.error("--pick must be between 1 and --takes")
    wanted = set(filter(None, (args.only or "").split(",")))
    os.makedirs(args.takes_dir, exist_ok=True)
    key = None
    for voice, gender in voices():
        for call in WORDS:
            if wanted and voice not in wanted and f"{voice}-{call}" not in wanted:
                continue
            takes = [os.path.join(args.takes_dir, f"{voice}-{call}-{n}.wav") for n in range(1, args.takes + 1)]
            for path in takes:
                if args.regenerate or not os.path.isfile(path):
                    key = key or api_key()
                    speak(key, voice, gender, call, path)
            chosen = takes[args.pick - 1]
            result = subprocess.run([sys.executable, "-I", PREPARE, voice, call, chosen, "--dest", args.dest],
                                    check=True, capture_output=True, text=True)
            print(f"{voice}-{call} take {args.pick}: {result.stdout.strip().split(': ', 1)[-1]}")


if __name__ == "__main__":
    main()
