# rekordbox notes

What we learned about rekordbox 7 (tested on 7.2.19, macOS, free plan with the FLX4 hardware
unlock) while building this. These findings drive the design; re-check them after a rekordbox update.

## Mapping files

- Bundled defaults: `rekordbox.app/Contents/Resources/MidiMappings/<device>.midi.csv`.
- User mappings: `~/Library/Application Support/Pioneer/rekordbox6/MidiMappings/<device>.midi.csv`,
  where `<device>` is the MIDI device name. A header-only file (`@file,1,DDJ-FLX4`) means
  "use the default".
- rekordbox loads a device's mapping when the device appears, and **rewrites the file** in its own
  form: rows sorted, comment rows dropped, deck columns expanded to full messages
  (`904D,914D,924D,934D`), options normalised (`Fast;`). Never store markers inside these files.
- Deck columns hold either a channel offset added to the input message, or a full 2-byte message.

## The FLX4 is special-cased

- rekordbox has built-in code per supported controller (`djplay::MidiMapDDJFLX4`,
  `MidiMapDDJGRV6`, ... in the binary). For the FLX4 it drives decks 1/2 directly from the hardware.
- Editing, deleting or disabling rows in the FLX4 **user** mapping does not stop that: play, cue,
  jog, loops, mixer and LOAD still reached decks 1/2. Tried: removing deck rows (they fall back to
  the default) and remapping them to unused addresses (ignored).
- The MIDI stream cannot be hidden from rekordbox on macOS: CoreMIDI sources go to every client.

**What works:** rename the FLX4's MIDI device, entity and endpoints (`kMIDIPropertyName`, as Audio
MIDI Setup does). rekordbox then treats it as an unknown device ("FLX4-RAW is connected"), creates
an empty `FLX4-RAW.midi.csv`, and ignores its MIDI. The **hardware unlock survives** (Performance
mode, 4 decks, no plan prompt), so it does not depend on the MIDI name. The model string
(`kMIDIPropertyModel = DDJ-FLX4`) is left alone and is how the router finds the hardware.

## What a generic (non-recognised) MIDI device can do

Tested by publishing a virtual device with a mapping and watching rekordbox's screen:

| Works | Does not work |
|---|---|
| Buttons: play, cue, sync, loops, hot cues, pad modes, LOAD | `JogRotate` / `JogTouch` / `Difference` (scratch, pitch bend, search). Ignored with any encoding |
| `Rotary` browse, `KnobSliderHiRes` mixer, tempo, CFX | |
| `FXnAssign.CHx`, `PitchBendUp/Down`, `SearchFwd/Rev` buttons | |
| LED and indicator output to the device | |

Measurements:
- `PitchBendUp/Down` held: about ±8% playback speed (+0.4 s over 4.27 s, −0.7 s over 8.28 s).
- `SearchFwd/Rev` held on a stopped deck: accelerates with hold time; 2 s ≈ 35 s of track, a 10-40 ms
  press barely moves. Good for a jog: small turns are fine, long turns travel.
- `FXnAssign.CHx`: the channel stays selected while the note is held (lever-like); release reverts.

## Other behaviour worth knowing

- **Play LED** (`9x 0B`) is steady while playing and blinks (on/off every ~0.5 s) while paused.
- **Load lock** (`DeckLoadLock=1` in `rekordbox3.settings`) stops loading onto a playing deck.
- Quitting rekordbox while a deck plays shows a "Now playing, quit rekordbox?" dialog; AppleScript
  `quit` then times out.
- rekordbox picks up a virtual device that appears after launch within a few seconds; messages sent
  before it shows "<device> is connected" are lost.
