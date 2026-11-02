import Foundation

/// `FLX4Deck --selftest`: exercises RouterCore with no hardware attached.
enum SelfTest {
    static var failures = 0

    static func expect(_ got: [Out], _ want: [Out], _ what: String) {
        if got == want { print("  ok   \(what)") } else {
            failures += 1
            print("  FAIL \(what)\n       got  \(got.map { "\($0.dest):\($0.msg)" })\n       want \(want.map { "\($0.dest):\($0.msg)" })")
        }
    }
    static func m(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) -> MIDIMsg { MIDIMsg(s: s, d1: d1, d2: d2) }
    static func rb(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) -> Out { Out(dest: .rekordbox, msg: m(s, d1, d2)) }
    static func fx(_ s: UInt8, _ d1: UInt8, _ d2: UInt8) -> Out { Out(dest: .flx4, msg: m(s, d1, d2)) }

    static func run() -> Bool {
        let c = RouterCore()
        print("routing, default decks 1|2")
        expect(c.input(m(0x90, 0x0B, 0x7F)), [rb(0x90, 0x0B, 0x7F)], "left PLAY -> deck 1")
        expect(c.input(m(0x91, 0x0B, 0x7F)), [rb(0x91, 0x0B, 0x7F)], "right PLAY -> deck 2")
        expect(c.input(m(0x97, 0x00, 0x7F)), [rb(0x97, 0x00, 0x7F)], "left pad 1 -> deck 1 pads")
        expect(c.input(m(0x96, 0x46, 0x7F)), [rb(0x96, 0x46, 0x7F)], "LOAD left -> deck 1")
        expect(c.input(m(0x96, 0x41, 0x7F)), [], "browse press stays on FLX4 mapping")
        expect(c.input(m(0x94, 0x47, 0x7F)), [], "FX unit stays on FLX4 mapping")

        print("rekordbox feedback before swap")
        expect(c.feedback(m(0x92, 0x0B, 0x7F)), [], "deck 3 PLAY LED is cached, not shown")
        expect(c.feedback(m(0x9B, 0x00, 0x7F)), [], "deck 3 hot cue 1 LED cached")
        expect(c.feedback(m(0x90, 0x0C, 0x7F)), [fx(0x90, 0x0C, 0x7F)], "deck 1 CUE LED shown on left")
        expect(c.feedback(m(0x9F, 0x02, 0x7F)), [], "deck 3 loaded indicator cached")

        print("swap left to deck 3 (SHIFT + headphone CUE)")
        let swap = c.input(m(0x90, 0x68, 0x7F))
        expect(swap, [fx(0x90, 0x0C, 0x00), fx(0x90, 0x0B, 0x7F), fx(0x97, 0x00, 0x7F), fx(0x9F, 0x00, 0x7F)],
               "swap replays deck 3 LEDs and clears deck 1-only LEDs")
        expect(c.input(m(0x90, 0x68, 0x00)), [], "swap button release is swallowed")
        assert(c.active == [2, 1])
        expect(c.input(m(0x90, 0x0B, 0x7F)), [rb(0x92, 0x0B, 0x7F)], "left PLAY -> deck 3")
        expect(c.input(m(0x98, 0x00, 0x7F)), [rb(0x9C, 0x00, 0x7F)], "left SHIFT+pad -> deck 3 shift pads")
        expect(c.input(m(0x96, 0x46, 0x7F)), [rb(0x96, 0x48, 0x7F)], "LOAD left -> deck 3")
        expect(c.input(m(0x91, 0x0B, 0x7F)), [rb(0x91, 0x0B, 0x7F)], "right still on deck 2")
        expect(c.input(m(0xB0, 0x22, 0x41)), [rb(0xB2, 0x22, 0x41)], "left jog -> deck 3")
        expect(c.feedback(m(0x90, 0x0C, 0x00)), [], "deck 1 LED hidden while left is on deck 3")
        expect(c.feedback(m(0x92, 0x0C, 0x7F)), [fx(0x90, 0x0C, 0x7F)], "deck 3 LED shown on left")
        expect(c.feedback(m(0x9F, 0x06, 0x7F)), [fx(0x9F, 0x04, 0x7F)], "deck 3 loop indicator -> left loop LED")

        print("soft takeover (pickup)")
        let d = RouterCore()
        expect(d.input(m(0xB0, 0x13, 100)), [rb(0xB0, 0x13, 100)], "fader on deck 1 to 100")
        expect(d.input(m(0xB0, 0x33, 5)), [rb(0xB0, 0x33, 5)], "fader LSB passes")
        _ = d.toggle(0)
        expect(d.input(m(0xB0, 0x13, 30)), [rb(0xB2, 0x13, 30)], "deck 3 fader unknown -> moves immediately")
        _ = d.toggle(0)  // back to deck 1 (value 100), physical fader now at 30
        assert(d.pickup[0][0x13] == 100, "pickup armed")
        expect(d.input(m(0xB0, 0x13, 50)), [], "fader below deck 1 value is held")
        expect(d.input(m(0xB0, 0x33, 9)), [], "LSB held while picking up")
        expect(d.input(m(0xB0, 0x13, 99)), [rb(0xB0, 0x13, 99)], "fader reaching deck 1 value picks up")
        expect(d.input(m(0xB0, 0x33, 9)), [rb(0xB0, 0x33, 9)], "LSB passes after pickup")
        _ = d.toggle(0); _ = d.toggle(0)
        expect(d.input(m(0xB0, 0x13, 99)), [rb(0xB0, 0x13, 99)], "no pickup when knob already matches")

        print("filter knob (global channel) follows the deck")
        let f = RouterCore()
        _ = f.toggle(1)
        expect(f.input(m(0xB6, 0x18, 64)), [rb(0xB6, 0x1A, 64)], "right CFX -> CH4 CFX")
        expect(f.input(m(0xB6, 0x38, 3)), [rb(0xB6, 0x3A, 3)], "right CFX LSB -> CH4")
        expect(f.input(m(0xB6, 0x17, 64)), [rb(0xB6, 0x17, 64)], "left CFX -> CH1")

        print("MASTER CUE swaps both sides")
        let b = RouterCore()
        _ = b.input(m(0x96, 0x63, 0x7F))
        if b.active != [2, 3] { failures += 1; print("  FAIL both sides swapped: \(b.active)") } else { print("  ok   both sides swapped") }

        print("parser (running status, sysex skip)")
        var got: [MIDIMsg] = []
        let bytes: [UInt8] = [0xF0, 0x00, 0x40, 0xF7, 0x90, 0x0B, 0x7F, 0x0C, 0x00, 0xF8, 0xB1, 0x13, 0x10]
        bytes.withUnsafeBufferPointer { MIDIBridge.parse($0.baseAddress!, $0.count) { got.append($0) } }
        if got == [m(0x90, 0x0B, 0x7F), m(0x90, 0x0C, 0x00), m(0xB1, 0x13, 0x10)] { print("  ok   parsed 3 messages") }
        else { failures += 1; print("  FAIL parser: \(got)") }

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        return failures == 0
    }
}
