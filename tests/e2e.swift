// End-to-end CoreMIDI test. Pretends to be both the FLX4 (virtual "FAKE-FLX4") and
// rekordbox (listens on / sends to "FLX4-4DECK"). Run the router headless with
//   FLX4_SOURCE=FAKE-FLX4 FLX4_DEST=FAKE-FLX4 FLX4Deck --headless
import CoreMIDI
import Foundation

var client = MIDIClientRef(), port = MIDIPortRef(), outPort = MIDIPortRef()
var fakeSrc = MIDIEndpointRef(), fakeDst = MIDIEndpointRef()
var gotRB: [[UInt8]] = [], gotFLX: [[UInt8]] = []
let lock = NSLock()

func bytes(_ l: UnsafePointer<MIDIPacketList>) -> [[UInt8]] {
    var r: [[UInt8]] = []
    for p in l.unsafeSequence() {
        let n = Int(p.pointee.length)
        let d = UnsafeRawPointer(p).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!).assumingMemoryBound(to: UInt8.self)
        var i = 0; while i + 2 < n + 0 && i < n { r.append([d[i], d[i + 1], d[i + 2]]); i += 3 }
    }
    return r
}
func find(_ name: String, src: Bool) -> MIDIEndpointRef {
    for i in 0..<(src ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()) {
        let e = src ? MIDIGetSource(i) : MIDIGetDestination(i)
        var s: Unmanaged<CFString>?; MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s)
        if (s?.takeRetainedValue() as String?) == name { return e }
    }
    return 0
}
func packet(_ b: [UInt8], _ f: (UnsafePointer<MIDIPacketList>) -> Void) {
    var buf = [UInt8](repeating: 0, count: 256)
    buf.withUnsafeMutableBytes { raw in
        let l = raw.baseAddress!.assumingMemoryBound(to: MIDIPacketList.self)
        MIDIPacketListAdd(l, 256, MIDIPacketListInit(l), 0, b.count, b)
        f(l)
    }
}
func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

MIDIClientCreate("e2e" as CFString, nil, nil, &client)
MIDISourceCreate(client, "FAKE-FLX4" as CFString, &fakeSrc)
MIDIDestinationCreateWithBlock(client, "FAKE-FLX4" as CFString, &fakeDst) { l, _ in lock.lock(); gotFLX += bytes(l); lock.unlock() }
MIDIInputPortCreateWithBlock(client, "rb-in" as CFString, &port) { l, _ in lock.lock(); gotRB += bytes(l); lock.unlock() }
MIDIOutputPortCreate(client, "rb-out" as CFString, &outPort)

let router = Process()
router.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
router.arguments = ["--headless"]
router.environment = ["FLX4_SOURCE": "FAKE-FLX4", "FLX4_DEST": "FAKE-FLX4", "HOME": NSHomeDirectory()]
try! router.run()
defer { router.terminate() }
pump(1.5)

let vSrc = find("FLX4-4DECK", src: true), vDst = find("FLX4-4DECK", src: false)
guard vSrc != 0, vDst != 0 else { print("FAIL virtual FLX4-4DECK not published"); router.terminate(); exit(1) }
print("ok   virtual device FLX4-4DECK visible to other apps")
MIDIPortConnectSource(port, vSrc, nil)
pump(0.3)

var fails = 0
func check(_ name: String, _ cond: Bool) { print(cond ? "ok   \(name)" : "FAIL \(name)"); if !cond { fails += 1 } }
func flx(_ b: [UInt8]) { packet(b) { MIDIReceived(fakeSrc, $0) }; pump(0.15) }
func rbSend(_ b: [UInt8]) { packet(b) { MIDISend(outPort, vDst, $0) }; pump(0.15) }
func takeRB() -> [[UInt8]] { lock.lock(); defer { gotRB = []; lock.unlock() }; return gotRB }
func takeFLX() -> [[UInt8]] { lock.lock(); defer { gotFLX = []; lock.unlock() }; return gotFLX }

flx([0x90, 0x0B, 0x7F]); check("FLX4 left PLAY reaches rekordbox as deck 1", takeRB() == [[0x90, 0x0B, 0x7F]])
rbSend([0x92, 0x0B, 0x7F]); check("deck 3 PLAY LED not shown while on deck 1", takeFLX().isEmpty)
flx([0x90, 0x68, 0x7F]); flx([0x90, 0x68, 0x00])
check("SHIFT+CUE swap sends deck 3 LEDs to FLX4", takeFLX().contains([0x90, 0x0B, 0x7F]))
check("swap combo not forwarded to rekordbox", takeRB().isEmpty)
flx([0x90, 0x0B, 0x7F]); check("FLX4 left PLAY now reaches deck 3", takeRB() == [[0x92, 0x0B, 0x7F]])
flx([0x96, 0x46, 0x7F]); check("LOAD left loads to deck 3", takeRB() == [[0x96, 0x48, 0x7F]])
rbSend([0x92, 0x0C, 0x7F]); check("deck 3 CUE LED lights FLX4 left", takeFLX() == [[0x90, 0x0C, 0x7F]])

router.terminate(); router.waitUntilExit()
print(fails == 0 ? "\nE2E PASS" : "\nE2E \(fails) FAILURE(S)")
exit(fails == 0 ? 0 : 1)
