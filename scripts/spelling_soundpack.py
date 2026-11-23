#!/usr/bin/env python3
"""
Build a "spelling keyboard" soundpack: every key says its name. Letters are spelled out ("ay",
"bee", "see"), digits are counted, and the other keys are named ("space", "comma", "delete").

The pack is monophonic: each key cuts off the name before it, so fast typing is heard as the
start of every name instead of a pile of overlapping words. That needs this fork of Thock.

The voice is a built-in macOS one, so this needs `swiftc` (Xcode command line tools) and `ffmpeg`.

    python3 scripts/spelling_soundpack.py                # Samantha, installed into Thock
    python3 scripts/spelling_soundpack.py --modifiers    # also name shift, command, option...
    python3 scripts/spelling_soundpack.py --output ./pack
"""

import argparse
import shutil
import string
import sys
import tempfile
import uuid
from pathlib import Path

from phoneme_soundpack import APPLE_VOICES, CUT_FADE_MS, PACK_NAMESPACE, SOUNDPACKS, Kind, render_apple, shape, write_pack

# Names run to their natural end; the cap only guards against a voice that rambles
SPOKEN = Kind(1200, 30, 0.12, trim_tail=True)

# Thock key name -> what the voice reads. Thock sees keys, not characters, so "1" is "one" even
# when shift makes it "!".
# A lone lowercase letter is read as its name. Uppercase comes out as "capital A", and phonemes
# are no better: the voice splits the diphthong in "ay" or "eye" into two separate vowels.
WORDS = {letter: letter for letter in string.ascii_lowercase}
WORDS.update({
    "0": "zero", "1": "one", "2": "two", "3": "three", "4": "four",
    "5": "five", "6": "six", "7": "seven", "8": "eight", "9": "nine",
    ".": "dot", ",": "comma", "/": "slash", "\\": "backslash", ";": "semicolon", "'": "quote",
    "`": "backtick", "[": "left bracket", "]": "right bracket", "-": "dash", "=": "equals",
    "*": "star", "+": "plus", "clear": "clear",
    "space": "space", "enter": "enter", "del": "delete", "tab": "tab", "esc": "escape",
    "arrLeft": "left", "arrRight": "right", "arrUp": "up", "arrDown": "down",
    "home": "home", "end": "end", "pgUp": "page up", "pgDn": "page down",
})
WORDS.update({f"f{n}": f"F {n}" for n in range(1, 13)})

# Off by default: shift would speak before every capital and command before every shortcut
MODIFIERS = {
    "shiftLeft": "shift", "shiftRight": "shift", "command": "command", "ctrlLeft": "control",
    "optionLeft": "option", "optionRight": "option", "capsLock": "caps lock", "fn": "function",
}


def clip_name(text: str) -> str:
    return text.lower().replace(" ", "-")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--voice", choices=sorted(APPLE_VOICES), default="samantha", help="macOS voice")
    parser.add_argument("--modifiers", action="store_true", help="also name the modifier keys")
    parser.add_argument("--sample-rate", type=int, default=48000, help="sample rate of the clips")
    parser.add_argument("--output", type=Path, default=None,
                        help="soundpack folder to write (default: spelling-keyboard-<voice> in Thock's custom soundpacks)")
    parser.add_argument("--name", default=None, help="soundpack name shown in Thock")
    parser.add_argument("--author", default="Unknown", help="soundpack author shown in Thock")
    args = parser.parse_args()

    for tool in ("swiftc", "ffmpeg"):
        if shutil.which(tool) is None:
            sys.exit(f"`{tool}` not found on PATH.")

    words = {**WORDS, **(MODIFIERS if args.modifiers else {})}
    keys = {key: clip_name(text) for key, text in words.items()}
    requests = {clip_name(text): f":{text}" for text in words.values()}

    with tempfile.TemporaryDirectory() as work:
        rendered = render_apple(args.voice, requests, args.sample_rate, Path(work))
    silent = sorted(name for name, samples in rendered.items() if not samples)
    if silent:
        sys.exit(f"The '{args.voice}' voice produced no audio for: {', '.join(silent)}.")
    clips = {name: shape(samples, SPOKEN, args.sample_rate) for name, samples in rendered.items()}

    config = {
        "id": str(uuid.uuid5(PACK_NAMESPACE, f"spelling-{args.voice}")).upper(),
        "metadata": {
            "name": args.name or f"Spelling Keyboard ({args.voice.capitalize()})",
            "brand": "Apple",
            "author": args.author,
            "category": "keyboard",
            "supportsKeyUp": False,
        },
        "license": {"type": "unknown", "url": ""},
        "monophonic": {"fadeMs": CUT_FADE_MS},
        # No "default" entry: keys without a name here stay silent
        "sounds": {key: {"down": [f"{clip}.wav"], "up": []} for key, clip in keys.items()},
    }
    output = args.output or SOUNDPACKS / f"spelling-keyboard-{args.voice}"
    write_pack(output, clips, config, args.sample_rate)
    print(f"Wrote {len(clips)} clips ({args.voice}, {args.sample_rate} Hz) to {output}")


if __name__ == "__main__":
    main()
