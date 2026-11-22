#!/usr/bin/env python3
"""
Build a "speaking keyboard" soundpack: every letter key plays the sound that letter most often
makes in English, and letter pairs such as "th", "sh" and "ee" play their own sound through the
soundpack "sequences" feature.

The clips are rendered with eSpeak NG at one fixed pitch, so consecutive keys chain into
monotone, robotic speech. Requires `espeak-ng` and `ffmpeg` on PATH (brew install espeak-ng ffmpeg).

    python3 scripts/phoneme_soundpack.py                    # install into Thock's custom soundpacks
    python3 scripts/phoneme_soundpack.py --voice robosoft --pitch 80
    python3 scripts/phoneme_soundpack.py --output ./pack    # write somewhere else
"""

import argparse
import array
import json
import math
import re
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

# Regenerating the pack keeps this id, so Thock keeps it selected.
PACK_ID = "9B3E5D52-7C1F-4E0A-B8D6-2F4A61C0E7A3"

DEFAULT_OUTPUT = Path.home() / "Library/Application Support/Thock/Soundpacks/speaking-keyboard"

# eSpeak voice variants. Base and top pitch are forced equal by render_voice() to get a monotone.
VOICES = {
    "plain": "",
    "klatt": "klatt 1\n",
    "klatt4": "klatt 4\n",
    "robosoft": (
        "klatt 5\n"
        "formant 0 100 125 100\nformant 1 96 90 80\nformant 2 97 70 90\n"
        "formant 3 97 60 90\nformant 4 97 60 90\nformant 5 100 50 90\n"
        "formant 6 90 50 100\nformant 7 100 50 100\nformant 8 100 50 100\n"
        "roughness 50\nvoicing 80\n"
    ),
    "unirobot": (
        "klatt 4\n"
        "formant 1 75 120 135\nformant 2 90 50 140\nformant 3 70 85 95\n"
        "formant 4 150 60 80\nformant 5 100 85 80\nformant 6 112 100 80\n"
        "formant 7 110 95 100\nformant 8 105 110 100\nconsonants 125 100\n"
        "tone 530 250 770 100 215 225\n"
    ),
}

# kind -> (longest clip in ms, fade-out in ms, level, how the level is measured)
# Stops are bursts with almost no energy, so they are matched by peak instead of RMS.
KINDS = {
    "vowel": (130, 20, 0.12, "rms"),
    "long": (170, 25, 0.12, "rms"),
    "glide": (190, 25, 0.12, "rms"),
    "sonorant": (100, 15, 0.10, "rms"),
    "fricative": (100, 12, 0.06, "rms"),
    "voiced-fricative": (100, 15, 0.08, "rms"),
    "affricate": (110, 12, 0.07, "rms"),
    "stop": (70, 8, 0.45, "peak"),
    "voiced-stop": (90, 15, 0.10, "rms"),
    "cluster": (140, 12, 0.45, "peak"),
}

# clip name -> (eSpeak phoneme mnemonics, kind)
# Verify a mnemonic with: espeak-ng -v en-us --ipa -q "[[tS]]"
CLIPS = {
    # Short vowels
    "ae": ("a", "vowel"),        # cat
    "eh": ("E", "vowel"),        # bed
    # eSpeak turns a lone "I" into "i", so render "It" and keep only the vowel
    "ih": ("It", "vowel"),       # sit
    "o": ("0", "vowel"),         # hot
    "uh": ("V", "vowel"),        # cup
    # Long vowels and diphthongs
    "ee": ("i:", "long"),        # see
    "oo": ("u:", "long"),        # moon
    "ay": ("eI", "glide"),       # day
    "oh": ("oU", "glide"),       # boat
    "ow": ("aU", "glide"),       # out
    "oy": ("OI", "glide"),       # boy
    "eye": ("aI", "glide"),      # high
    "ar": ("A@", "glide"),       # car
    "er": ("3", "long"),         # her
    "or": ("O@", "glide"),       # for
    # Consonants
    # eSpeak renders silence for a voiced stop on its own, so release each into a schwa
    "b": ("b@", "voiced-stop"), "d": ("d@", "voiced-stop"), "g": ("g@", "voiced-stop"),
    "p": ("p", "stop"), "t": ("t", "stop"), "k": ("k", "stop"),
    "f": ("f", "fricative"), "s": ("s", "fricative"), "h": ("h", "fricative"),
    "sh": ("S", "fricative"),                             # ship
    # Voiced consonants are faint or silent on their own in eSpeak, so they also get a schwa
    "v": ("v@", "voiced-fricative"), "z": ("z@", "voiced-fricative"),
    "dh": ("D@", "voiced-fricative"),                     # the
    "ch": ("tS", "affricate"), "j": ("dZ@", "affricate"), # chip, jam
    "l": ("l@", "sonorant"), "m": ("m@", "sonorant"), "n": ("n@", "sonorant"),
    "ng": ("N", "sonorant"), "r": ("r@", "sonorant"),
    "w": ("w@", "sonorant"), "y": ("j@", "sonorant"),
    "ks": ("ks", "cluster"),
}

KEYS = {
    "a": "ae", "b": "b", "c": "k", "d": "d", "e": "eh", "f": "f", "g": "g", "h": "h", "i": "ih",
    "j": "j", "k": "k", "l": "l", "m": "m", "n": "n", "o": "o", "p": "p", "q": "k", "r": "r",
    "s": "s", "t": "t", "u": "uh", "v": "v", "w": "w", "x": "ks", "y": "y", "z": "z",
}

# The first key of a sequence has already sounded by the time the sequence completes, so each
# entry is what the *last* key should add. None keeps that key silent and cuts nothing.
SEQUENCES = {
    "t h": "dh", "s h": "sh", "c h": "ch", "p h": "f", "n g": "ng",
    # "t" then "c" is the start of "tch"; the "c" must not say /k/
    "t c": None, "t c h": "ch",
    "w h": None, "c k": None,
    # "q" already said /k/, so "u" only adds the /w/
    "q u": "w",
    "i g h": "eye",
    "e e": "ee", "e a": "ee", "o o": "oo",
    "a i": "ay", "a y": "ay", "o a": "oh",
    "o u": "ow", "o w": "ow", "o i": "oy", "o y": "oy",
    "a r": "ar", "o r": "or", "e r": "er", "i r": "er", "u r": "er",
}
# A doubled consonant is one sound
SEQUENCES.update({f"{c} {c}": None for c in "bcdfgklmnprstvz"})


def run(*command: str) -> subprocess.CompletedProcess:
    return subprocess.run(command, check=True, capture_output=True)


def espeak_data_dir() -> Path:
    version = run("espeak-ng", "--version").stdout.decode()
    match = re.search(r"Data at:\s*(.+)", version)
    if not match:
        sys.exit("Could not find the eSpeak NG data directory in `espeak-ng --version`.")
    return Path(match.group(1).strip())


def decode(path: Path, sample_rate: int) -> list[float]:
    """Decode to mono floats at the target rate, dropping silence before the first sound."""
    raw = run("ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-ar", str(sample_rate), "-f", "s16le", "-").stdout
    pcm = array.array("h")
    pcm.frombytes(raw)
    samples = [sample / 32768.0 for sample in pcm]
    peak = max((abs(sample) for sample in samples), default=0.0)
    if peak < 0.001:
        return []
    # Leading silence is added latency. The threshold follows the clip's own level because
    # eSpeak renders some consonants 30 dB quieter than vowels.
    threshold = peak * 0.03
    start = next(i for i, sample in enumerate(samples) if abs(sample) >= threshold)
    return samples[start:]


def shape(samples: list[float], kind: str, sample_rate: int) -> list[float]:
    max_ms, fade_ms, level, measure = KINDS[kind]
    clip = samples[: sample_rate * max_ms // 1000]
    if not clip:
        return clip
    fade = min(len(clip), sample_rate * fade_ms // 1000)
    for i in range(fade):
        clip[len(clip) - fade + i] *= 1.0 - (i + 1) / fade
    peak = max(abs(sample) for sample in clip)
    if peak == 0:
        return clip
    if measure == "rms":
        rms = math.sqrt(sum(sample * sample for sample in clip) / len(clip))
        gain = min(level / rms, 0.9 / peak)
    else:
        gain = level / peak
    return [sample * gain for sample in clip]


def write_wav(path: Path, samples: list[float], sample_rate: int) -> None:
    pcm = array.array("h", (int(max(-1.0, min(1.0, sample)) * 32767) for sample in samples))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


def render_clips(voice: str, pitch: int, sample_rate: int) -> dict[str, list[float]]:
    with tempfile.TemporaryDirectory() as work:
        work_path = Path(work)
        # A custom voice variant has to live inside an eSpeak data directory
        data = work_path / "espeak-ng-data"
        shutil.copytree(espeak_data_dir(), data)
        variant = f"language variant\nname speakingkeyboard\npitch {pitch} {pitch}\n{VOICES[voice]}"
        (data / "voices" / "!v" / "speakingkeyboard").write_text(variant)

        clips = {}
        for name, (phonemes, kind) in CLIPS.items():
            source = work_path / f"{name}.wav"
            run("espeak-ng", f"--path={work_path}", "-v", "en-us+speakingkeyboard",
                "-w", str(source), f"[[{phonemes}]]")
            clips[name] = shape(decode(source, sample_rate), kind, sample_rate)
            if not clips[name]:
                sys.exit(f"eSpeak NG produced no audio for '{name}' ([[{phonemes}]]).")
        return clips


def build_config(name: str, author: str) -> dict:
    def files(clip):
        return [] if clip is None else [f"{clip}.wav"]

    return {
        "id": PACK_ID,
        "metadata": {
            "name": name,
            "brand": "eSpeak NG",
            "author": author,
            "category": "keyboard",
            "supportsKeyUp": False,
        },
        "license": {"type": "unknown", "url": ""},
        # No "default" entry: space, digits and punctuation stay silent
        "sounds": {key: {"down": files(clip), "up": []} for key, clip in KEYS.items()},
        "sequences": {keys: {"down": files(clip)} for keys, clip in SEQUENCES.items()},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--voice", choices=sorted(VOICES), default="klatt", help="eSpeak voice variant")
    parser.add_argument("--pitch", type=int, default=95, help="fixed pitch of the whole bank in Hz")
    parser.add_argument("--sample-rate", type=int, default=48000, help="sample rate of the clips")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="soundpack folder to write")
    parser.add_argument("--name", default="Speaking Keyboard", help="soundpack name shown in Thock")
    parser.add_argument("--author", default="Unknown", help="soundpack author shown in Thock")
    args = parser.parse_args()

    for tool in ("espeak-ng", "ffmpeg"):
        if shutil.which(tool) is None:
            sys.exit(f"`{tool}` not found on PATH.")

    clips = render_clips(args.voice, args.pitch, args.sample_rate)

    args.output.mkdir(parents=True, exist_ok=True)
    for stale in args.output.glob("*.wav"):
        stale.unlink()
    for name, samples in clips.items():
        write_wav(args.output / f"{name}.wav", samples, args.sample_rate)
    (args.output / "config.json").write_text(json.dumps(build_config(args.name, args.author), indent=2) + "\n")

    print(f"Wrote {len(clips)} clips ({args.voice}, {args.pitch} Hz, {args.sample_rate} Hz) to {args.output}")


if __name__ == "__main__":
    main()
