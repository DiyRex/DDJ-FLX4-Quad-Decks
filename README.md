# FLX4 4Deck

Turns a Pioneer DDJ-FLX4 into a simple 4-deck controller for rekordbox 7 (free plan works).
The left side controls deck 1 or 3, and the right side controls deck 2 or 4. You swap with one button combo.
An on-screen overlay always shows which deck each side controls.

> **Status: early testing.** Routing, LED feedback and layout swapping are tested; channel faders on
> decks 3/4 are still being verified on hardware.

Your normal FLX4 2-channel layout stays the default. The 4-deck layout is only active while
rekordbox is started through this app. It is put back automatically when rekordbox quits.

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
| Swap both sides | **MASTER CUE** (button next to the headphones level) |
| Load a track | **LOAD** on a side loads into that side's *active* deck |
| Pick a deck with the mouse | Click a deck tile on the overlay, or use the menu bar item (`1\|2`) |

Everything on a side follows the active deck: play, cue, jog, tempo, sync, loops, pads, the channel
fader, trim, EQ and the filter (CFX) knob. The browser, crossfader, FX section and master stay global.

**Pickup:** after a swap, a knob or fader whose position doesn't match the new deck is held
until you move it past the deck's value. The overlay shows it in yellow ("pick up: FADER · TEMPO").
So swapping never makes the volume or tempo jump.

**Overlay:** drag it anywhere. It stays visible over fullscreen rekordbox. Each deck tile shows
▶ playing / ● loaded and a level meter. Hide or show it from the menu bar item.

What you give up in 4-deck mode: **TAP BPM** (SHIFT + headphone CUE), because that combo is now the swap.

## Troubleshooting
- **Overlay says "rekordbox is in 2-channel mode":** rekordbox was opened directly. Quit it, then
  choose *Start 4-Deck Session* from the menu bar item.
- **Something looks stuck:** use *Restore 2-Channel Layout* from the menu. Your original FLX4 mapping
  file is backed up in `~/Library/Application Support/FLX4-4Deck/`.
- **Log:** `~/Library/Logs/FLX4-4Deck.log`. To see every MIDI message, run
  `"/Applications/FLX4 4Deck.app/Contents/MacOS/FLX4Deck" --sniff` in Terminal.

## How it works
rekordbox always reads the FLX4 directly, so the app can't simply redirect its messages. Instead:
1. While a 4-deck session runs, the FLX4 user mapping (`DDJ-FLX4.midi.csv` in
   `~/Library/Application Support/Pioneer/rekordbox6/MidiMappings/`) is swapped for a version with every
   deck row disabled. Only the global controls remain.
2. The app publishes a virtual MIDI device, **FLX4-4DECK**, with a 4-deck mapping. It reads the FLX4,
   rewrites the deck controls to deck 1–4 MIDI channels, and sends rekordbox's LED feedback for the
   active deck back to the FLX4.
3. When rekordbox quits, the original FLX4 mapping file is restored byte-for-byte.

Both mappings are generated from rekordbox's own bundled FLX4 default by `tools/gen_mappings.py`.

## Build
```
./build.sh          # app + dmg in dist/
./build.sh --test   # also runs the CoreMIDI end-to-end test
```
Requires the Xcode command line tools. `FLX4Deck --selftest` runs the routing tests.
