# FLX4 4Deck

Turns a Pioneer DDJ-FLX4 into a simple 4-deck controller for rekordbox 7 (free plan works).
The left side controls deck 1 or 3, and the right side controls deck 2 or 4. You swap with one button combo.
An overlay beside the MacBook notch always shows which deck each side controls.

> **Status: early testing.** Deck separation, load, browse, Beat FX assign and jog nudge/search are
> verified in rekordbox; hardware testing is ongoing.

Your normal FLX4 setup is never changed. 4-deck mode exists only while rekordbox is started through
this app, and the FLX4 is back to normal as soon as rekordbox quits.

## Install
1. Open `FLX4-4Deck.dmg` and drag **FLX4 4Deck** to Applications.
2. First launch: right-click the app → **Open** (it is self-signed, not notarized).
3. In rekordbox: **Preferences → View → Layout → Deck**, choose **4 Deck** (one time only; rekordbox remembers it).

## Use
| Want | Do |
|---|---|
| 4-deck set | Quit rekordbox → open **FLX4 4Deck** (it launches rekordbox for you) |
| Normal 2-channel set | Just open rekordbox as usual |
| Swap a side (1↔3 or 2↔4) | **SHIFT + headphone CUE** on that channel |
| Swap both sides | **MASTER CUE** |
| Load a track | **LOAD** on a side loads into that side's *active* deck |
| Beat FX on deck 1 / 2 | Beat FX channel **1** / **2** |
| Beat FX on deck 3 / 4 | **SHIFT +** Beat FX channel **1** / **2** |
| Pick a deck with the mouse | Click a deck in the overlay, or use the menu bar item (`1\|2`) |

Everything on a side follows the active deck: play, cue, sync, loops, pads, tempo, the channel
fader, trim, EQ and the filter (CFX) knob. Browser, crossfader, FX section and master stay global.

**Jog wheels:** rekordbox only accepts jog input from controllers it recognises, so in 4-deck mode
the jog works as:
- **outer edge on a playing deck:** nudge (speeds up / slows down while you turn) for beat-matching
- **touching the top, a stopped deck, or SHIFT + jog:** search (moves the playhead; slow turns move a
  little, long turns speed up) for cueing

Scratching is not available in 4-deck mode.

**Pickup:** after a swap, a knob or fader whose position doesn't match the new deck is held until
you move it past the deck's value. The overlay shows it in yellow (`⇕ FADER`).

**Overlay:** two small pills either side of the notch (menu bar item → *Overlay Position* →
*Free* to drag them anywhere, *Overlay Size* for Small / Medium / Large). Each deck shows ▶ playing,
● loaded and a level meter.

Given up in 4-deck mode: scratching, and **TAP BPM** (its SHIFT + headphone CUE combo is the swap).

## Troubleshooting
- **Overlay says "rekordbox is in 2-channel mode":** rekordbox was opened directly. Quit it, then
  choose *Start 4-Deck Session* from the menu bar item.
- **FLX4 not working in normal rekordbox after a crash:** open FLX4 4Deck once (it repairs itself),
  or use *Restore FLX4 to 2-Channel Mode* from its menu.
- **Log:** `~/Library/Logs/FLX4-4Deck.log`; menu → *Log MIDI Messages* records every message.

## How it works
rekordbox recognises the FLX4 by its MIDI name and then runs built-in code that wires every control
to decks 1/2, ignoring any mapping file. So for a 4-deck session the app:
1. renames the FLX4's MIDI ports (`DDJ-FLX4` → `FLX4-RAW`), so rekordbox treats it as an unknown
   device. The hardware unlock is unaffected.
2. publishes a virtual MIDI device, **FLX4-4DECK**, with a 4-deck mapping
   (`Resources/mappings/FLX4-4DECK.midi.csv`, generated from rekordbox's own FLX4 default by
   `tools/gen_mappings.py`). The router reads the FLX4, rewrites deck controls to deck 1–4 channels,
   turns jog movement into nudge/search buttons, and sends LED feedback for the active deck back.
3. renames the FLX4 back to `DDJ-FLX4` when rekordbox quits.

## Build
```
./build.sh          # app + dmg in dist/
./build.sh --test   # also runs the CoreMIDI end-to-end test (quit the app first)
```
Requires the Xcode command line tools. `FLX4Deck --selftest` runs the routing tests.
