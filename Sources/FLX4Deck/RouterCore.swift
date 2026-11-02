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

    static let cfxKey: UInt8 = 0x17
    static let keyNames: [UInt8: String] = [0x00: "TEMPO", 0x04: "TRIM", 0x07: "HI", 0x0B: "MID",
                                            0x0F: "LOW", 0x13: "FADER", cfxKey: "CFX"]

    // MARK: FLX4 -> rekordbox

    func input(_ m: MIDIMsg) -> [Out] {
        switch m.ch {
        case 0, 1:
            let side = m.ch
            if m.isNote && m.d1 == Self.swapNote {
                return m.isPress ? toggle(side) : []
            }
            let deck = active[side]
            if m.type == 0xB0, let (key, msb) = Self.deckCCKey(m.d1),
               !takeover(side: side, deck: deck, key: key, isMSB: msb, value: m.d2) { return [] }
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
                let side = Int(base - 0x17), deck = active[side]
                guard takeover(side: side, deck: deck, key: Self.cfxKey, isMSB: lsbBit == 0, value: m.d2) else { return [] }
                return [rb(MIDIMsg(s: m.s, d1: lsbBit | (0x17 + UInt8(deck)), d2: m.d2))]
            }
            return []  // other globals reach rekordbox directly from the FLX4

        default:
            return []  // FX units (ch 4/5) etc. are handled by the FLX4 mapping itself
        }
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

    private func takeover(side: Int, deck: Int, key: UInt8, isMSB: Bool, value: UInt8) -> Bool {
        guard isMSB else { return pickup[side][key] == nil }
        let prev = phys[side][key]
        phys[side][key] = value
        if let t = pickup[side][key] {
            let d = Int(value) - Int(t)
            let crossed = prev.map { (Int($0) - Int(t)).signum() != d.signum() } ?? false
            guard abs(d) <= Self.pickupWindow || crossed else { return false }
            pickup[side][key] = nil
        }
        deckVal[deck][key] = value
        return true
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
        var outs: [Out] = []
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
            if m.d1 == 0x0B && m.isNote { decks[deck].playing = m.isPress }
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
