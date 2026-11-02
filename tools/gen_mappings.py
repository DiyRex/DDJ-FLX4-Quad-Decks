#!/usr/bin/env python3
"""Generate the rekordbox MIDI mapping for the FLX4 4Deck virtual device.

Input : rekordbox's bundled DDJ-FLX4.midi.csv (the 2-channel default).
Output: FLX4-4DECK.midi.csv, the mapping for the router's virtual MIDI device.

During a 4-deck session the app renames the FLX4's MIDI ports, so rekordbox's built-in
FLX4 code (which hard-wires every control to decks 1/2) no longer attaches to it. Every
control then reaches rekordbox only through the virtual device, so this mapping carries:
  * global rows (browser, crossfader, FX, master...) unchanged,
  * deck rows extended to decks 3/4,
  * CFX (filter) knobs for channels 3/4,
  * Beat FX channel assign (CH1-4/MASTER) so the FX lever can follow the active deck,
  * PitchBendUp/Down and SearchFwd/Rev buttons per deck: rekordbox ignores jog-type input
    from generic MIDI devices, so the router turns jog movement into nudges (deck playing)
    or search (deck stopped, platter touched, or SHIFT).

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


def row(*cells: str) -> list[str]:
    return (list(cells) + [""] * COLS)[:COLS]


EXTRA_ROWS = (
    # Beat FX channel assign, same addresses as the DDJ-GRV6 (FX1) and the next channel (FX2).
    [row(f"FX{u}Assign.{t}", "", "Button", f"9{3 + u}1{i}", *[""] * 10, f"FX{u} assign {t}")
     for u in (1, 2) for i, t in enumerate(["CH1", "CH2", "CH3", "CH4", "MASTER"])]
    # Nudge buttons driven by the router from jog movement (notes unused by the FLX4).
    + [row("PitchBendUp", "PitchBendUp", "Button", "9021", "0", "1", "2", "3", *[""] * 6, "Jog nudge forward"),
       row("PitchBendDown", "PitchBendDown", "Button", "9023", "0", "1", "2", "3", *[""] * 6, "Jog nudge back"),
       row("SearchFwd", "SearchFwd", "Button", "9024", "0", "1", "2", "3", *[""] * 6, "Jog search forward"),
       row("SearchRev", "SearchRev", "Button", "9025", "0", "1", "2", "3", *[""] * 6, "Jog search back")]
)


def extend(v1: str, v2: str) -> tuple[str, str]:
    if not v1 or not v2:
        return "", ""
    if len(v1) == 4:  # full hex message
        a, b = int(v1, 16), int(v2, 16)
        return f"{a + 2 * (b - a):04X}", f"{a + 3 * (b - a):04X}"
    a, b = int(v1), int(v2)
    return str(a + 2 * (b - a)), str(a + 3 * (b - a))


def is_deck_row(r: list[str]) -> bool:
    return any(r[i] for i in (IN_D1, IN_D2, OUT_D1, OUT_D2)) or r[0] in DECK_GLOBAL_NAMES


def main(src: Path, out: Path) -> None:
    rows = [(r + [""] * COLS)[:COLS] for r in csv.reader(io.StringIO(src.read_text()))]
    virt = []
    for r in rows:
        name = r[0]
        if name.startswith("@file"):
            virt.append(row("@file", "1", VIRTUAL_DEVICE))
        elif name.startswith("#") or not name:
            if name.startswith("#name") or not name or (name.startswith("# ") and not r[3]):
                virt.append(r)  # header and section titles; disabled rows stay out
        elif name in DROP_NAMES:
            continue
        elif is_deck_row(r):
            v = list(r)
            v[IN_D3], v[IN_D4] = extend(r[IN_D1], r[IN_D2])
            v[OUT_D3], v[OUT_D4] = extend(r[OUT_D1], r[OUT_D2])
            virt.append(v)
            for n, msg, comment in CFX_EXTRA.get(name, []):
                virt.append(row(n, n, r[2], msg, *[""] * 9) [:13] + [r[13], comment])
        else:
            virt.append(r)  # global control (browser, crossfader, FX, master, parameters)
    virt += [row("# FLX4 4Deck extras")] + EXTRA_ROWS

    out.mkdir(parents=True, exist_ok=True)
    stale = out / "DDJ-FLX4.4deck.midi.csv"  # layout from the earlier file-swap approach
    if stale.exists():
        stale.unlink()
    buf = io.StringIO()
    csv.writer(buf, lineterminator="\r\n").writerows(virt)
    (out / f"{VIRTUAL_DEVICE}.midi.csv").write_text(buf.getvalue())
    print(f"wrote {out / f'{VIRTUAL_DEVICE}.midi.csv'} ({len(virt)} rows)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
