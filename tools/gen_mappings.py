#!/usr/bin/env python3
"""Generate the two rekordbox MIDI mapping CSVs for FLX4 4-deck mode.

Input : rekordbox's bundled DDJ-FLX4.midi.csv (the 2-channel default).
Output:
  DDJ-FLX4.4deck.midi.csv  -> installed as the FLX4 user mapping while 4-deck mode is on.
                              Global controls only (browser, crossfader, FX, master...);
                              every deck row is disabled with '#', so raw FLX4 deck
                              messages do nothing and cannot fight the router.
  FLX4-4DECK.midi.csv      -> mapping for the router's virtual MIDI device. All deck
                              rows, extended to decks 3/4.

Deck column values are either MIDI-channel offsets (0/1, pads 7/9 and 8/10) or full
2-byte messages (Load 9646/9647, indicators 9F00/9F01). In both cases deck N follows
deck1 + (N-1) * (deck2 - deck1), which gives 2/3, 11/13, 12/14, 9648/9649, 9F02/9F03.

Usage: gen_mappings.py <bundled DDJ-FLX4.midi.csv> <out dir>
"""
import csv
import io
import sys
from pathlib import Path

VIRTUAL_DEVICE = "FLX4-4DECK"
MARKER = "# FLX4-4DECK generated layout (2-channel layout is restored when rekordbox quits)"
COLS = 15
IN_D1, IN_D2, IN_D3, IN_D4 = 4, 5, 6, 7
OUT_D1, OUT_D2, OUT_D3, OUT_D4 = 9, 10, 11, 12

# Mixer knobs the FLX4 sends on the global channel but which belong to a deck.
CFX_EXTRA = {
    "CFXParameterCH1": [("CFXParameterCH3", "B619", "CH3 CFX Depth"),
                        ("CFXParameterCH4", "B61A", "CH4 CFX Depth")],
}
DECK_GLOBAL_NAMES = {"CFXParameterCH1", "CFXParameterCH2"}
# Row consumed by the router as the deck-swap combo (SHIFT + headphone CUE).
DROP_NAMES = {"TapBpm"}


def extend(v1: str, v2: str) -> tuple[str, str]:
    if not v1 or not v2:
        return "", ""
    if len(v1) == 4:  # full hex message
        a, b = int(v1, 16), int(v2, 16)
        return f"{a + 2 * (b - a):04X}", f"{a + 3 * (b - a):04X}"
    a, b = int(v1), int(v2)
    return str(a + 2 * (b - a)), str(a + 3 * (b - a))


# rekordbox MERGES a user mapping over its built-in FLX4 default: a missing row falls back
# to the default. So deck rows must stay present but listen to addresses the FLX4 hardware
# never sends (channels 11-14), with their LED outputs removed.
CC_TYPES = {"KnobSliderHiRes", "KnobSlider", "JogRotate", "Difference", "Rotary"}
_next = {"cc": 0, "note": 0, "pad": 0}


def dead(kind: str, deck: int) -> str:
    n = _next[kind]
    _next[kind] += 1 if deck == 1 else 0
    if kind == "cc":
        assert n < 0x20, "out of dead hi-res CC slots"
        return f"{0xBC + deck:02X}{n:02X}"
    base = {"note": 0x9C, "pad": 0x9B}[kind]
    ch = base + deck if kind == "note" else (0x9B if deck == 0 else 0x9E)
    assert n < 0x80, "out of dead note slots"
    return f"{ch:02X}{n:02X}"


def neutralize(r: list[str]) -> list[str]:
    v = list(r)
    kind = "cc" if r[2] in CC_TYPES else ("pad" if r[2] in ("Pad", "DdjSxPad") else "note")
    for i in (IN_D1, IN_D2, IN_D3, IN_D4, OUT_D1, OUT_D2, OUT_D3, OUT_D4, 8):
        v[i] = ""
    if r[2] in ("Indicator", "Value") and not r[3] and not r[IN_D1]:
        v[3] = ""                       # output-only row: present but silent
    elif r[IN_D1] or r[IN_D2]:
        v[3] = ""
        v[IN_D1], v[IN_D2] = dead(kind, 0), dead(kind, 1)
    else:
        v[3] = dead(kind, 0)            # global-channel deck control (CFX knobs)
        _next[kind] += 1
    return v


def is_deck_row(r: list[str]) -> bool:
    return any(r[i] for i in (IN_D1, IN_D2, OUT_D1, OUT_D2)) or r[0] in DECK_GLOBAL_NAMES


def main(src: Path, out: Path) -> None:
    rows = [(r + [""] * COLS)[:COLS] for r in csv.reader(io.StringIO(src.read_text()))]
    flx, virt = [], []
    for r in rows:
        name = r[0]
        if name.startswith("@file"):
            flx.append(r)
            virt.append(["@file", "1", VIRTUAL_DEVICE] + [""] * (COLS - 3))
        elif name.startswith("#") or not name:
            flx.append(r)          # comments, disabled rows, section headers
            if name.startswith("#name") or not name or (name.startswith("# ") and not r[3]):
                virt.append(r)
        elif r[2] == "Parameter":
            flx.append(r)
            virt.append(r)
        elif is_deck_row(r):
            flx.append(neutralize(r))  # dead in the FLX4 4-deck layout
            if name in DROP_NAMES:
                continue
            v = list(r)
            v[IN_D3], v[IN_D4] = extend(r[IN_D1], r[IN_D2])
            v[OUT_D3], v[OUT_D4] = extend(r[OUT_D1], r[OUT_D2])
            virt.append(v)
            for n, msg, comment in CFX_EXTRA.get(name, []):
                virt.append([n, n, r[2], msg] + [""] * 9 + [r[13], comment])
        else:
            flx.append(r)          # global control, stays on the FLX4 itself

    out.mkdir(parents=True, exist_ok=True)
    for fname, data in (("DDJ-FLX4.4deck.midi.csv", flx), (f"{VIRTUAL_DEVICE}.midi.csv", virt)):
        buf = io.StringIO()
        csv.writer(buf, lineterminator="\r\n").writerows(data)
        (out / fname).write_text(buf.getvalue())
        print(f"wrote {out / fname} ({len(data)} rows)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
