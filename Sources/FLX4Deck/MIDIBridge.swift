import CoreMIDI
import Foundation

/// Wires RouterCore to CoreMIDI: reads the FLX4, publishes the virtual "FLX4-4DECK"
/// device rekordbox maps, and sends LED feedback back to the FLX4.
final class MIDIBridge {
    static let virtualName = "FLX4-4DECK"
    static let hardwareModel = "DDJ-FLX4"
    // Overridable so the end-to-end test can stand in for the hardware. By default the FLX4
    // is found by its USB model string, which stays put while the app renames its ports.
    let hwSourceName = ProcessInfo.processInfo.environment["FLX4_SOURCE"]
    let hwDestName = ProcessInfo.processInfo.environment["FLX4_DEST"]
    private var jogTimer: DispatchSourceTimer?

    let core = RouterCore()
    private let lock = NSLock()
    private var client = MIDIClientRef(), inPort = MIDIPortRef(), outPort = MIDIPortRef()
    private var vSource = MIDIEndpointRef(), vDest = MIDIEndpointRef()
    private var hwSource = MIDIEndpointRef(), hwDest = MIDIEndpointRef()

    var verbose = false
    var log: (String) -> Void = { print($0) }
    private(set) var hardwareConnected = false

    func start() throws {
        try check(MIDIClientCreateWithBlock("FLX4 4Deck" as CFString, &client) { [weak self] n in
            if n.pointee.messageID == .msgSetupChanged { DispatchQueue.main.async { self?.connectHardware() } }
        }, "client")
        try check(MIDIOutputPortCreate(client, "to FLX4" as CFString, &outPort), "out port")
        try check(MIDIInputPortCreateWithBlock(client, "from FLX4" as CFString, &inPort) { [weak self] list, _ in
            self?.receive(list, fromHardware: true)
        }, "in port")
        try check(MIDISourceCreate(client, Self.virtualName as CFString, &vSource), "virtual source")
        try check(MIDIDestinationCreateWithBlock(client, Self.virtualName as CFString, &vDest) { [weak self] list, _ in
            self?.receive(list, fromHardware: false)
        }, "virtual destination")
        // Stable IDs so rekordbox recognises the same device on every launch.
        MIDIObjectSetIntegerProperty(vSource, kMIDIPropertyUniqueID, 0x4634_4431)
        MIDIObjectSetIntegerProperty(vDest, kMIDIPropertyUniqueID, 0x4634_4432)
        for e in [vSource, vDest] {
            MIDIObjectSetStringProperty(e, kMIDIPropertyManufacturer, "FLX4 4Deck" as CFString)
            MIDIObjectSetStringProperty(e, kMIDIPropertyModel, Self.virtualName as CFString)
        }
        connectHardware()

        // Ends a jog nudge shortly after the wheel stops turning.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "jog", qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.route { $0.jogIdle() } }
        t.resume()
        jogTimer = t
    }

    /// (Re)attach to the FLX4 endpoints; called at start and whenever MIDI setup changes.
    func connectHardware() {
        let src = Self.findHardware(hwSourceName, sources: true), dst = Self.findHardware(hwDestName, sources: false)
        if src != hwSource {
            if hwSource != 0 { MIDIPortDisconnectSource(inPort, hwSource) }
            if src != 0 { MIDIPortConnectSource(inPort, src, nil) }
            hwSource = src
        }
        hwDest = dst
        let now = src != 0 && dst != 0
        if now != hardwareConnected {
            hardwareConnected = now
            log(now ? "FLX4 connected (\(Self.displayName(src)))" : "FLX4 not found")
            if now { resendLEDs() }
        }
    }

    // MARK: deck control (UI thread)

    func toggle(side: Int) { route { $0.toggle(side) } }
    func setDeck(side: Int, deck: Int) { route { $0.setDeck(side: side, deck: deck) } }

    func snapshot() -> (active: [Int], decks: [DeckInfo], pickup: [[UInt8: UInt8]], swap: Int) {
        lock.lock(); defer { lock.unlock() }
        return (core.active, core.decks, core.pickup, core.swapSerial)
    }

    private func resendLEDs() {
        route { $0.replayActive() }
    }

    private func route(_ f: (RouterCore) -> [Out]) {
        lock.lock(); let outs = f(core); lock.unlock()
        send(outs)
    }

    // MARK: MIDI I/O

    private func receive(_ list: UnsafePointer<MIDIPacketList>, fromHardware: Bool) {
        var outs: [Out] = []
        for packet in list.unsafeSequence() {
            let len = Int(packet.pointee.length)
            let data = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIPacket>.offset(of: \MIDIPacket.data)!)
                .assumingMemoryBound(to: UInt8.self)
            Self.parse(data, len) { m in
                lock.lock()
                let o = fromHardware ? core.input(m) : core.feedback(m)
                lock.unlock()
                if verbose { log((fromHardware ? "FLX4 > " : "RB   > ") + "\(m)  ->  " + o.map { "\($0.dest == .flx4 ? "FLX4" : "RB"):\($0.msg)" }.joined(separator: " ")) }
                outs += o
            }
        }
        send(outs)
    }

    private func send(_ outs: [Out]) {
        guard !outs.isEmpty else { return }
        for dest in [Dest.rekordbox, Dest.flx4] {
            let msgs = outs.filter { $0.dest == dest }.map(\.msg)
            if msgs.isEmpty || (dest == .flx4 && hwDest == 0) { continue }
            // Chunked so long LED replays never overflow the packet list buffer.
            stride(from: 0, to: msgs.count, by: 128).forEach { i in
                sendChunk(Array(msgs[i..<min(i + 128, msgs.count)]), to: dest)
            }
        }
    }

    private func sendChunk(_ msgs: [MIDIMsg], to dest: Dest) {
        let size = 1024 + msgs.count * 16
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buf.deallocate() }
        let list = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var pkt = MIDIPacketListInit(list)
        for m in msgs {
            let bytes = [m.s, m.d1, m.d2]
            pkt = MIDIPacketListAdd(list, size, pkt, 0, m.length, bytes)
        }
        if dest == .rekordbox { MIDIReceived(vSource, list) } else { MIDISend(outPort, hwDest, list) }
    }

    /// Channel-voice parser with running status; sysex and realtime bytes are skipped.
    static func parse(_ p: UnsafePointer<UInt8>, _ n: Int, _ emit: (MIDIMsg) -> Void) {
        var i = 0, running: UInt8 = 0
        while i < n {
            let b = p[i]
            if b >= 0xF8 { i += 1; continue }
            if b == 0xF0 { while i < n && p[i] != 0xF7 { i += 1 }; i += 1; continue }
            if b >= 0xF0 { running = 0; i += 1; continue }
            if b & 0x80 != 0 { running = b; i += 1 }
            guard running != 0 else { i += 1; continue }
            let need = (running & 0xF0 == 0xC0 || running & 0xF0 == 0xD0) ? 1 : 2
            guard i + need <= n else { break }
            emit(MIDIMsg(s: running, d1: p[i], d2: need == 2 ? p[i + 1] : 0))
            i += need
        }
    }

    /// The FLX4 endpoint: by explicit name when given (tests), else by the device's model.
    static func findHardware(_ name: String?, sources: Bool) -> MIDIEndpointRef {
        if let name { return find(name, sources: sources) }
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let e = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            var entity = MIDIEntityRef(), device = MIDIDeviceRef()
            guard MIDIEndpointGetEntity(e, &entity) == noErr, MIDIEntityGetDevice(entity, &device) == noErr else { continue }
            if stringProperty(device, kMIDIPropertyModel) == hardwareModel { return e }
        }
        return 0
    }

    static func stringProperty(_ o: MIDIObjectRef, _ key: CFString) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(o, key, &s)
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    static func find(_ name: String, sources: Bool) -> MIDIEndpointRef {
        let count = sources ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations()
        for i in 0..<count {
            let e = sources ? MIDIGetSource(i) : MIDIGetDestination(i)
            if displayName(e) == name { return e }
        }
        return 0
    }

    static func displayName(_ e: MIDIEndpointRef) -> String {
        var s: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(e, kMIDIPropertyDisplayName, &s)
        return (s?.takeRetainedValue() as String?) ?? ""
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        if status != noErr { throw NSError(domain: "CoreMIDI", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "\(what) failed (\(status))"]) }
    }
}
