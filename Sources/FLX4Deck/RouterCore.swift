import Foundation

/// One 3-byte channel voice message.
struct MIDIMsg: Equatable, CustomStringConvertible {
    var s: UInt8, d1: UInt8, d2: UInt8
    var type: UInt8 { s & 0xF0 }
    var ch: Int { Int(s & 0x0F) }
    var isNote: Bool { type == 0x90 || type == 0x80 }
    var isPress: Bool { type == 0x90 && d2 > 0 }
    var length: Int { (type == 0xC0 || type == 0xD0) ? 2 : 3 }
    var description: String { String(format: "%02X %02X %02X", s, d1, d2) }
}

enum Dest { case rekordbox, flx4 }
struct Out: Equatable { let dest: Dest; let msg: MIDIMsg }

struct DeckInfo { var playing = false; var loaded = false; var level: UInt8 = 0 }

/// Pure routing logic, no CoreMIDI. Sides: 0 = left (decks 1/3), 1 = right (decks 2/4).
/// Decks are 0-based here (0...3) and shown 1-based in the UI.
///
/// FLX4 (hardware) channel layout        Virtual FLX4-4DECK layout (rekordbox)
///   ch 0/1   deck controls left/right     ch 0..3   decks 1..4
///   ch 7/8   left pads / +shift           ch 7..14  pads: 7+2*deck (+1 shift)
///   ch 9/10  right pads / +shift
///   ch 6     global; 0x46/0x47 load,      ch 6      load 0x46..0x49, CFX 0x17..0x1A
///            CC 0x17/0x18 filter knobs
///   ch 15    0x00/01 loaded, 0x04/05 loop ch 15     0x00..03 loaded, 0x04..07 loop
///
/// During a session the FLX4 is renamed so rekordbox's built-in FLX4 code ignores it; every
/// control reaches rekordbox only through here. Global controls pass through unchanged.
/// rekordbox ignores jog-type input from generic devices, so jog movement becomes
/// PitchBendUp/Down presses (notes 0x21/0x23 on the deck channel).
final class RouterCore {
    static let swapNote: UInt8 = 0x68      // SHIFT + headphone CUE (was TAP BPM)
    static let swapBothNote: UInt8 = 0x63  // MASTER CUE (unassigned in the FLX4 default)
    static let pickupWindow = 3

    private(set) var active = [0, 1]
    private(set) var decks = [DeckInfo](repeating: .init(), count: 4)
    private(set) var swapSerial = 0
    /// Controls waiting for the physical knob/fader to reach the deck's value: side -> key -> target.
    private(set) var pickup = [[UInt8: UInt8]](repeating: [:], count: 2)

    private var phys = [[UInt8: UInt8]](repeating: [:], count: 2)     // side -> key -> physical MSB
    private var deckVal = [[UInt8: UInt8]](repeating: [:], count: 4)  // deck -> key -> last value sent
    private var leds = [[UInt16: UInt8]](repeating: [:], count: 4)    // deck -> FLX4 address -> value
    /// Where each held button's press went, so its release goes to the same deck after a swap.
    private var held: [UInt16: MIDIMsg] = [:]
    /// Jog button held per side (nudge or search note), its deck, and time of the last tick.
    private var jogNote: [UInt8?] = [nil, nil], jogDeck = [0, 1], jogLast: [TimeInterval] = [0, 0]
    static let jogHold: TimeInterval = 0.08
    static let nudgeUp: UInt8 = 0x21, nudgeDown: UInt8 = 0x23, searchFwd: UInt8 = 0x24, searchRev: UInt8 = 0x25
    /// SHIFT held on either side (Beat FX channel select uses it for decks 3/4).
    private var shiftHeld = [false, false]
    /// Play LED per deck: on/off and when it last went off. Blinking = paused, steady = playing.
    private var playLED = [false, false, false, false]
    private var playLastOff: [TimeInterval] = [0, 0, 0, 0]
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    static let cfxKey: UInt8 = 0x17
    static let keyNames: [UInt8: String] = [0x00: "TEMPO", 0x04: "TRIM", 0x07: "HI", 0x0B: "MID",
                                            0x0F: "LOW", 0x13: "FADER", cfxKey: "CFX"]

    // MARK: FLX4 -> rekordbox

    func input(_ m: MIDIMsg) -> [Out] {
        let heldKey = UInt16(m.ch) << 8 | UInt16(m.d1)
        if m.isNote && !m.isPress, let h = held.removeValue(forKey: heldKey) {
            return [rb(MIDIMsg(s: m.type | (h.s & 0x0F), d1: h.d1, d2: m.d2))]
        }
        let outs = route(m)
        if m.isPress, outs.count == 1, outs[0].dest == .rekordbox, outs[0].msg.isNote { held[heldKey] = outs[0].msg }
        return outs
    }

    private func route(_ m: MIDIMsg) -> [Out] {
        switch m.ch {
        case 0, 1:
            let side = m.ch
            if m.isNote && m.d1 == Self.swapNote {
                return m.isPress ? toggle(side) : []
            }
            let deck = active[side]
            if m.isNote && m.d1 == 0x3F { shiftHeld[side] = m.isPress }
            if m.type == 0xB0 && ((0x21...0x23).contains(m.d1) || m.d1 == 0x29) { return jog(side, m.d1, m.d2) }
            if m.type == 0xB0, let (key, msb) = Self.deckCCKey(m.d1) {
                let cc = m.d1 & 0x1F
                return absolute(side: side, key: key, isMSB: msb, value: m.d2) { d, isMSB in
                    MIDIMsg(s: 0xB0 | UInt8(d), d1: isMSB ? cc : cc | 0x20, d2: 0)
                }
            }
            return [rb(MIDIMsg(s: m.type | UInt8(deck), d1: m.d1, d2: m.d2))]

        case 7...10:
            let side = (m.ch - 7) / 2, shift = (m.ch - 7) % 2
            return [rb(MIDIMsg(s: m.type | UInt8(7 + active[side] * 2 + shift), d1: m.d1, d2: m.d2))]

        case 6:
            if m.isNote && (m.d1 == 0x46 || m.d1 == 0x47) {
                return [rb(MIDIMsg(s: m.s, d1: 0x46 + UInt8(active[Int(m.d1 - 0x46)]), d2: m.d2))]
            }
            if m.isNote && m.d1 == Self.swapBothNote {
                return m.isPress ? toggle(0) + toggle(1) : []
            }
            let base = m.d1 & 0x1F, lsbBit = m.d1 & 0x20
            if m.type == 0xB0 && (base == 0x17 || base == 0x18) && (m.d1 & ~0x3F) == 0 {
                let side = Int(base - 0x17)
                return absolute(side: side, key: Self.cfxKey, isMSB: lsbBit == 0, value: m.d2) { d, isMSB in
                    MIDIMsg(s: 0xB6, d1: (isMSB ? 0 : 0x20) | (0x17 + UInt8(d)), d2: 0)
                }
            }
            return [rb(m)]  // browser, crossfader, headphones, master: unchanged

        case 4...5 where m.isNote && (m.d1 == 0x10 || m.d1 == 0x11):
            // Beat FX channel select: 1/2 -> CH1/CH2, SHIFT + 1/2 -> CH3/CH4 (FXnAssign.CHx = 0x10 + ch).
            // The release follows the press via `held`, even if SHIFT is let go first.
            let shift = shiftHeld[0] || shiftHeld[1]
            return [rb(MIDIMsg(s: m.s, d1: m.d1 + (shift ? 2 : 0), d2: m.d2))]

        default:
            return [rb(m)]  // FX units, settings: unchanged
        }
    }

    /// Relative jog tick (0x40 = no movement). rekordbox ignores jog input from generic devices,
    /// so the router holds a button while the wheel turns:
    ///   outer edge on a playing deck         -> PitchBendUp/Down (nudge, beat-matching)
    ///   platter touched, deck stopped, SHIFT -> SearchFwd/Rev    (move the playhead, cueing)
    private func jog(_ side: Int, _ cc: UInt8, _ v: UInt8) -> [Out] {
        let d = Int(v) - 0x40
        guard d != 0 else { return [] }
        let deck = active[side]
        let nudge = isPlaying(deck) && (cc == 0x21 || cc == 0x23)
        let note = nudge ? (d > 0 ? Self.nudgeUp : Self.nudgeDown) : (d > 0 ? Self.searchFwd : Self.searchRev)
        jogLast[side] = clock()
        guard note != jogNote[side] || jogDeck[side] != deck else { return [] }
        var outs = releaseJog(side)
        jogNote[side] = note
        jogDeck[side] = deck
        outs.append(rb(MIDIMsg(s: 0x90 | UInt8(deck), d1: note, d2: 0x7F)))
        return outs
    }

    private func releaseJog(_ side: Int) -> [Out] {
        guard let note = jogNote[side] else { return [] }
        jogNote[side] = nil
        return [rb(MIDIMsg(s: 0x90 | UInt8(jogDeck[side]), d1: note, d2: 0))]
    }

    func isPlaying(_ deck: Int) -> Bool { playLED[deck] && clock() - playLastOff[deck] > 0.7 }

    /// Called on a short timer: ends a jog hold once the wheel has stopped, refreshes play state.
    func jogIdle() -> [Out] {
        for d in 0..<4 { decks[d].playing = isPlaying(d) }
        return (0...1).flatMap { s in jogNote[s] != nil && clock() - jogLast[s] > Self.jogHold ? releaseJog(s) : [] }
    }

    /// Absolute (hi-res) per-deck CCs that need soft takeover. Returns (takeover key, isMSB).
    static func deckCCKey(_ cc: UInt8) -> (UInt8, Bool)? {
        let msb = cc < 0x20, base = cc & 0x1F
        switch base {
        case 0x00, 0x05: return (0x00, msb)  // tempo (shifted variant shares the fader)
        case 0x04, 0x07, 0x0B, 0x0F, 0x13: return (base, msb)
        default: return nil                  // jogs, buttons: relative or momentary
        }
    }

    /// One absolute (hi-res) control move, with soft takeover after a swap.
    /// `addr(deck, isMSB)` gives the virtual-device address of this control on a deck.
    private func absolute(side: Int, key: UInt8, isMSB: Bool, value: UInt8,
                          addr: (Int, Bool) -> MIDIMsg) -> [Out] {
        let deck = active[side]
        var passes: Bool
        if isMSB {
            let prev = phys[side][key]
            phys[side][key] = value
            passes = true
            if let t = pickup[side][key] {
                let d = Int(value) - Int(t)
                let crossed = prev.map { (Int($0) - Int(t)).signum() != d.signum() } ?? false
                if abs(d) <= Self.pickupWindow || crossed { pickup[side][key] = nil } else { passes = false }
            }
        } else {
            passes = pickup[side][key] == nil
        }
        guard passes else { return [] }
        if isMSB { deckVal[deck][key] = value }
        var a = addr(deck, isMSB); a.d2 = value
        return [rb(a)]
    }

    // MARK: deck switching

    func toggle(_ side: Int) -> [Out] { setDeck(side: side, deck: active[side] ^ 2) }

    func setDeck(side: Int, deck: Int) -> [Out] {
        guard (0...1).contains(side), (0...3).contains(deck), deck % 2 == side else { return [] }
        let old = active[side]
        active[side] = deck
        swapSerial += 1
        pickup[side] = [:]
        for (key, p) in phys[side] {
            if let v = deckVal[deck][key], abs(Int(p) - Int(v)) > Self.pickupWindow { pickup[side][key] = v }
        }
        guard old != deck else { return [] }
        var outs = releaseJog(side)
        for (addr, _) in leds[old] where leds[deck][addr] == nil {
            outs.append(fx(MIDIMsg(s: UInt8(addr >> 8), d1: UInt8(addr & 0xFF), d2: 0)))
        }
        for (addr, v) in leds[deck].sorted(by: { $0.key < $1.key }) {
            outs.append(fx(MIDIMsg(s: UInt8(addr >> 8), d1: UInt8(addr & 0xFF), d2: v)))
        }
        return outs
    }

    /// Current LED state of both active decks, e.g. after the FLX4 is re-plugged.
    func replayActive() -> [Out] {
        active.flatMap { deck in
            leds[deck].sorted(by: { $0.key < $1.key }).map {
                fx(MIDIMsg(s: UInt8($0.key >> 8), d1: UInt8($0.key & 0xFF), d2: $0.value))
            }
        }
    }

    // MARK: rekordbox -> FLX4 (LEDs, meters)

    func feedback(_ m: MIDIMsg) -> [Out] {
        var deck: Int, s = m.s, d1 = m.d1
        switch m.ch {
        case 0...3:
            deck = m.ch
            s = m.type | UInt8(deck % 2)
            if m.d1 == 0x0B && m.isNote {
                playLED[deck] = m.isPress
                if !m.isPress { playLastOff[deck] = clock() }
            }
            if m.d1 == 0x02 && m.type == 0xB0 { decks[deck].level = m.d2 }
        case 7...14:
            deck = (m.ch - 7) / 2
            s = m.type | UInt8(7 + (deck % 2) * 2 + (m.ch - 7) % 2)
        case 15 where m.d1 < 8:
            deck = Int(m.d1 % 4)
            d1 = (m.d1 < 4 ? 0 : 4) + UInt8(deck % 2)
            if m.d1 < 4 { decks[deck].loaded = m.d2 > 0 }
        default:
            return [fx(m)]
        }
        let out = MIDIMsg(s: s, d1: d1, d2: m.d2)
        if m.type != 0xB0 || m.d1 != 0x02 {  // don't replay stale meter values
            leds[deck][UInt16(s) << 8 | UInt16(d1)] = m.d2
        }
        return active[deck % 2] == deck ? [fx(out)] : []
    }

    private func rb(_ m: MIDIMsg) -> Out { Out(dest: .rekordbox, msg: m) }
    private func fx(_ m: MIDIMsg) -> Out { Out(dest: .flx4, msg: m) }
}
