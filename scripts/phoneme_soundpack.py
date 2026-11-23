#!/usr/bin/env python3
"""
Build a "speaking keyboard" soundpack: every letter key plays the sound that letter most often
makes in English, and letter pairs such as "th", "sh" and "ow" are completed by their second key.

The pack is monophonic ("legato"): each key fades out the sound before it, so vowels are recorded
at full length and simply last until the next key. It relies on the soundpack "monophonic" and
"sequences" features, so it needs this fork of Thock; stock Thock would play the letters only and
let the long vowels ring over each other.

Voices come from eSpeak NG (brew install espeak-ng) or from the built-in macOS voices (needs
`swiftc` from the Xcode command line tools). Both need `ffmpeg` on PATH.

    python3 scripts/phoneme_soundpack.py                     # eSpeak Klatt4, installed into Thock
    python3 scripts/phoneme_soundpack.py --voice samantha    # macOS Samantha
    python3 scripts/phoneme_soundpack.py --voice klatt --pitch 80   # eSpeak monotone at 80 Hz
    python3 scripts/phoneme_soundpack.py --output ./pack     # write somewhere else
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
import uuid
import wave
from pathlib import Path
from typing import NamedTuple

# Each voice gets a stable id derived from this one, so regenerating a pack keeps it selected in Thock.
PACK_NAMESPACE = uuid.UUID("9B3E5D52-7C1F-4E0A-B8D6-2F4A61C0E7A3")

SOUNDPACKS = Path.home() / "Library/Application Support/Thock/Soundpacks"

# How long the previous key's sound takes to fade out when the next key cuts it
CUT_FADE_MS = 20

# eSpeak voice variants.
ESPEAK_VOICES = {
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

# macOS voices that honour IPA input. List identifiers with:
#   swift -e 'import AVFoundation; AVSpeechSynthesisVoice.speechVoices().forEach { print($0.identifier) }'
APPLE_VOICES = {
    "samantha": "com.apple.voice.compact.en-US.Samantha",
}


class Kind(NamedTuple):
    max_ms: int
    fade_ms: int
    level: float
    # Stops are bursts with almost no energy, so they are matched by peak instead of RMS
    measure: str = "rms"
    # Sustained sounds run to their natural end, so the silence after it has to go before the fade
    trim_tail: bool = False


KINDS = {
    # Full-length vowels: the next key decides how long they are heard
    "sustained": Kind(320, 40, 0.12, trim_tail=True),
    "sustained-diphthong": Kind(450, 40, 0.12, trim_tail=True),
    # eSpeak's short "i" is the start of "it", so it has to stop before the "t"
    "sustained-checked": Kind(140, 40, 0.12, trim_tail=True),
    # The second half of a diphthong, added by the second key of a pair such as "ow"
    "glide": Kind(130, 20, 0.12),
    "long-glide": Kind(170, 25, 0.12),
    "sonorant": Kind(100, 15, 0.10),
    "fricative": Kind(100, 12, 0.06),
    "voiced-fricative": Kind(100, 15, 0.08),
    "affricate": Kind(110, 12, 0.07),
    "stop": Kind(70, 8, 0.45, measure="peak"),
    "voiced-stop": Kind(90, 15, 0.10),
    "cluster": Kind(140, 12, 0.45, measure="peak"),
}

# phoneme -> (eSpeak mnemonics, IPA for macOS voices)
# Verify an eSpeak mnemonic with: espeak-ng -v en-us --ipa -q "[[tS]]"
# The macOS voices drop "ɹ", "ɡ" (the IPA letter) and "ɝ"; they want plain "r" and "g".
PHONEMES = {
    "ae": ("a", "æ"),            # cat
    "eh": ("E", "ɛ"),            # bed
    # eSpeak turns a lone "I" into "i", so render "It" and keep only the vowel
    "ih": ("It", "ɪ"),           # sit
    "o": ("0", "ɑ"),             # hot
    "uh": ("V", "ʌ"),            # cup
    "ee": ("i:", "i"),           # see
    "oo": ("u:", "u"),           # moon
    "eye": ("aI", "aɪ"),         # high
    # eSpeak renders silence for a voiced stop on its own, and other voiced consonants come out
    # faint, so each is released into a schwa. The macOS voices need the schwa on every consonant.
    "b": ("b@", "bə"), "d": ("d@", "də"), "g": ("g@", "gə"),
    "p": ("p", "pə"), "t": ("t", "tə"), "k": ("k", "kə"),
    "f": ("f", "fə"), "s": ("s", "sə"), "h": ("h", "hə"),
    "sh": ("S", "ʃə"),                                    # ship
    "v": ("v@", "və"), "z": ("z@", "zə"),
    "dh": ("D@", "ðə"),                                   # the
    "ch": ("tS", "tʃə"), "j": ("dZ@", "dʒə"),             # chip, jam
    "l": ("l@", "lə"), "m": ("m@", "mə"), "n": ("n@", "nə"),
    "ng": ("N", "ŋə"), "r": ("r@", "rə"),
    "w": ("w@", "wə"), "y": ("j@", "jə"),
    "ks": ("ks", "ksə"),
}


class Clip(NamedTuple):
    phoneme: str
    kind: str
    # Set where a schwa-carried macOS rendering needs different shaping from the bare eSpeak one
    apple_kind: str | None = None


# clip file name (without ".wav") -> what it is cut from
CLIPS = {
    "ae": Clip("ae", "sustained"),
    "eh": Clip("eh", "sustained"),
    "ih": Clip("ih", "sustained-checked", "sustained"),
    "o": Clip("o", "sustained"),
    "uh": Clip("uh", "sustained"),
    "ee": Clip("ee", "sustained"),
    "oo": Clip("oo", "sustained"),
    "eye": Clip("eye", "sustained-diphthong"),
    "glide-ih": Clip("ih", "glide"),
    "glide-oo": Clip("oo", "long-glide"),
    "b": Clip("b", "voiced-stop"), "d": Clip("d", "voiced-stop"), "g": Clip("g", "voiced-stop"),
    "p": Clip("p", "stop", "voiced-stop"), "t": Clip("t", "stop", "voiced-stop"),
    "k": Clip("k", "stop", "voiced-stop"),
    "f": Clip("f", "fricative", "voiced-fricative"), "s": Clip("s", "fricative", "voiced-fricative"),
    "h": Clip("h", "fricative", "voiced-fricative"), "sh": Clip("sh", "fricative", "voiced-fricative"),
    "v": Clip("v", "voiced-fricative"), "z": Clip("z", "voiced-fricative"),
    "dh": Clip("dh", "voiced-fricative"),
    "ch": Clip("ch", "affricate"), "j": Clip("j", "affricate"),
    "l": Clip("l", "sonorant"), "m": Clip("m", "sonorant"), "n": Clip("n", "sonorant"),
    "ng": Clip("ng", "sonorant"), "r": Clip("r", "sonorant"),
    "w": Clip("w", "sonorant"), "y": Clip("y", "sonorant"),
    "ks": Clip("ks", "cluster"),
}

KEYS = {
    "a": "ae", "b": "b", "c": "k", "d": "d", "e": "eh", "f": "f", "g": "g", "h": "h", "i": "ih",
    "j": "j", "k": "k", "l": "l", "m": "m", "n": "n", "o": "o", "p": "p", "q": "k", "r": "r",
    "s": "s", "t": "t", "u": "uh", "v": "v", "w": "w", "x": "ks", "y": "y", "z": "z",
}

# The first key of a sequence has already sounded by the time the sequence completes, so each
# entry is only what the *last* key still has to add. None keeps that key silent, which leaves
# the sound before it playing.
SEQUENCES = {
    "t h": "dh", "s h": "sh", "c h": "ch", "p h": "f", "n g": "ng",
    # "t" then "c" is the start of "tch"; the "c" must not say /k/, and "t" plus "sh" is "ch"
    "t c": None, "t c h": "sh",
    "w h": None, "c k": None,
    # "q" already said /k/, so "u" only adds the /w/
    "q u": "w",
    "i g h": "eye",
    "e e": "ee", "e a": "ee", "o o": "oo",
}
# A diphthong is its first vowel plus a glide, and the first vowel is already playing.
# Vowel + "r" needs no entry: the "r" key's own sound colours the vowel it cuts.
SEQUENCES.update({keys: "glide-ih" for keys in ("a i", "a y", "o i", "o y", "e i", "e y")})
SEQUENCES.update({keys: "glide-oo" for keys in ("o u", "o w", "a u", "a w", "e w", "o a")})
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
    spec = KINDS[kind]
    clip = list(samples)
    if spec.trim_tail and clip:
        threshold = max(abs(sample) for sample in clip) * 0.03
        while clip and abs(clip[-1]) < threshold:
            clip.pop()
    clip = clip[: sample_rate * spec.max_ms // 1000]
    if not clip:
        return clip
    fade = min(len(clip), sample_rate * spec.fade_ms // 1000)
    for i in range(fade):
        clip[len(clip) - fade + i] *= 1.0 - (i + 1) / fade
    peak = max(abs(sample) for sample in clip)
    if peak == 0:
        return clip
    if spec.measure == "rms":
        rms = math.sqrt(sum(sample * sample for sample in clip) / len(clip))
        gain = min(spec.level / rms, 0.9 / peak)
    else:
        gain = spec.level / peak
    return [sample * gain for sample in clip]


def write_wav(path: Path, samples: list[float], sample_rate: int) -> None:
    pcm = array.array("h", (int(max(-1.0, min(1.0, sample)) * 32767) for sample in samples))
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        output.writeframes(pcm.tobytes())


def render_espeak(voice: str, pitch: int | None, sample_rate: int, work: Path) -> dict[str, list[float]]:
    # A custom voice variant has to live inside an eSpeak data directory
    data = work / "espeak-ng-data"
    shutil.copytree(espeak_data_dir(), data)
    # Equal base and top pitch gives a monotone; without it the voice keeps its own intonation
    pitch_line = f"pitch {pitch} {pitch}\n" if pitch else ""
    variant = f"language variant\nname speakingkeyboard\n{pitch_line}{ESPEAK_VOICES[voice]}"
    (data / "voices" / "!v" / "speakingkeyboard").write_text(variant)

    rendered = {}
    for name, (mnemonics, _) in PHONEMES.items():
        source = work / f"{name}.wav"
        run("espeak-ng", f"--path={work}", "-v", "en-us+speakingkeyboard", "-w", str(source), f"[[{mnemonics}]]")
        rendered[name] = decode(source, sample_rate)
    return rendered


def render_apple(voice: str, sample_rate: int, work: Path) -> dict[str, list[float]]:
    tool = work / "apple_voice_clips"
    run("swiftc", "-O", str(Path(__file__).with_name("apple_voice_clips.swift")), "-o", str(tool))
    clips = work / "clips"
    clips.mkdir()
    try:
        run(str(tool), APPLE_VOICES[voice], str(clips), *(f"{name}={ipa}" for name, (_, ipa) in PHONEMES.items()))
    except subprocess.CalledProcessError as error:
        sys.exit(error.stderr.decode().strip() or f"Rendering the '{voice}' voice failed.")
    rendered = {}
    for name in PHONEMES:
        source = clips / f"{name}.caf"
        rendered[name] = decode(source, sample_rate) if source.exists() else []
    return rendered


def render_clips(voice: str, pitch: int | None, sample_rate: int) -> dict[str, list[float]]:
    apple = voice in APPLE_VOICES
    with tempfile.TemporaryDirectory() as work:
        work_path = Path(work)
        rendered = render_apple(voice, sample_rate, work_path) if apple else render_espeak(voice, pitch, sample_rate, work_path)
    silent = sorted(name for name, samples in rendered.items() if not samples)
    if silent:
        sys.exit(f"The '{voice}' voice produced no audio for: {', '.join(silent)}.")
    return {
        name: shape(rendered[clip.phoneme], (clip.apple_kind if apple else None) or clip.kind, sample_rate)
        for name, clip in CLIPS.items()
    }


def build_config(voice: str, name: str, author: str) -> dict:
    def files(clip):
        return [] if clip is None else [f"{clip}.wav"]

    return {
        "id": str(uuid.uuid5(PACK_NAMESPACE, voice)).upper(),
        "metadata": {
            "name": name,
            "brand": "Apple" if voice in APPLE_VOICES else "eSpeak NG",
            "author": author,
            "category": "keyboard",
            "supportsKeyUp": False,
        },
        "license": {"type": "unknown", "url": ""},
        "monophonic": {"fadeMs": CUT_FADE_MS},
        # No "default" entry: space, digits and punctuation stay silent
        "sounds": {key: {"down": files(clip), "up": []} for key, clip in KEYS.items()},
        "sequences": {keys: {"down": files(clip)} for keys, clip in SEQUENCES.items()},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--voice", choices=sorted({**ESPEAK_VOICES, **APPLE_VOICES}), default="klatt4",
                        help="eSpeak voice variant or macOS voice")
    parser.add_argument("--pitch", type=int, default=None,
                        help="eSpeak only: force one fixed pitch in Hz for a monotone (default: the voice's own intonation)")
    parser.add_argument("--sample-rate", type=int, default=48000, help="sample rate of the clips")
    parser.add_argument("--output", type=Path, default=None,
                        help="soundpack folder to write (default: speaking-keyboard-<voice> in Thock's custom soundpacks)")
    parser.add_argument("--name", default=None, help="soundpack name shown in Thock")
    parser.add_argument("--author", default="Unknown", help="soundpack author shown in Thock")
    args = parser.parse_args()

    apple = args.voice in APPLE_VOICES
    if apple and args.pitch:
        sys.exit("--pitch only applies to eSpeak voices.")
    for tool in ("swiftc" if apple else "espeak-ng", "ffmpeg"):
        if shutil.which(tool) is None:
            sys.exit(f"`{tool}` not found on PATH.")

    output = args.output or SOUNDPACKS / f"speaking-keyboard-{args.voice}"
    name = args.name or f"Speaking Keyboard ({args.voice.capitalize()})"
    clips = render_clips(args.voice, args.pitch, args.sample_rate)

    output.mkdir(parents=True, exist_ok=True)
    for stale in output.glob("*.wav"):
        stale.unlink()
    for clip, samples in clips.items():
        write_wav(output / f"{clip}.wav", samples, args.sample_rate)
    (output / "config.json").write_text(json.dumps(build_config(args.voice, name, args.author), indent=2) + "\n")

    pitch = f", {args.pitch} Hz monotone" if args.pitch else ""
    print(f"Wrote {len(clips)} clips ({args.voice}{pitch}, {args.sample_rate} Hz) to {output}")


if __name__ == "__main__":
    main()
