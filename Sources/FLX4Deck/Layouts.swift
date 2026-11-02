import CoreMIDI
import Foundation

/// Starts and ends 4-deck mode.
///
/// rekordbox recognises the FLX4 by its MIDI name ("DDJ-FLX4") and then runs built-in code
/// that wires every control straight to decks 1/2, ignoring user mappings. For a 4-deck
/// session the FLX4's MIDI ports are renamed so rekordbox treats it as an unknown device and
/// only the router's virtual "FLX4-4DECK" device (with our mapping) drives rekordbox.
/// Ending the session restores the "DDJ-FLX4" name. The FLX4 mapping file is never touched,
/// so normal 2-channel use is exactly as before.
enum Layouts {
    static let originalName = "DDJ-FLX4"
    static let sessionName = "FLX4-RAW"

    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser
    static var rbDir: URL { home.appendingPathComponent("Library/Application Support/Pioneer/rekordbox6/MidiMappings") }
    static var virtualFile: URL { rbDir.appendingPathComponent("\(MIDIBridge.virtualName).midi.csv") }
    /// Blank mapping rekordbox creates for the renamed FLX4; removed again on restore.
    static var sessionStubFile: URL { rbDir.appendingPathComponent("\(sessionName).midi.csv") }
    static var stateDir: URL { home.appendingPathComponent("Library/Application Support/FLX4-4Deck") }
    /// Kept in our own folder (rekordbox rewrites its mapping files).
    static var installedFlag: URL { stateDir.appendingPathComponent("4deck-installed") }

    static var is4DeckInstalled: Bool { fm.fileExists(atPath: installedFlag.path) }

    static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "mappings")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../../../Resources/mappings/\(name).csv").standardized
    }

    static func install4Deck() throws {
        guard let virt = bundled("\(MIDIBridge.virtualName).midi"), fm.fileExists(atPath: virt.path) else {
            throw err("The 4-deck mapping is missing from the app bundle")
        }
        guard renameHardware(to: sessionName) else {
            throw err("DDJ-FLX4 not found. Connect it and try again.")
        }
        try fm.createDirectory(at: rbDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try replace(virtualFile, with: virt)
        fm.createFile(atPath: installedFlag.path, contents: nil)
    }

    /// Puts the FLX4 back to normal. Safe to call any time; also repairs a leftover rename.
    static func restore2Channel() throws {
        renameHardware(to: originalName)
        for f in [virtualFile, sessionStubFile] where fm.fileExists(atPath: f.path) { try fm.removeItem(at: f) }
        try? fm.removeItem(at: installedFlag)
    }

    /// True when the FLX4 is connected but still carries the session name (e.g. after a crash).
    static var hardwareLeftRenamed: Bool { hardwareObjects().contains { MIDIBridge.stringProperty($0, kMIDIPropertyName) == sessionName } }

    /// Renames the FLX4 device, its entity and both endpoints. False if the FLX4 isn't connected.
    @discardableResult
    static func renameHardware(to name: String) -> Bool {
        let objs = hardwareObjects()
        for o in objs where MIDIBridge.stringProperty(o, kMIDIPropertyName) != name {
            MIDIObjectSetStringProperty(o, kMIDIPropertyName, name as CFString)
        }
        return !objs.isEmpty
    }

    private static func hardwareObjects() -> [MIDIObjectRef] {
        var objs: [MIDIObjectRef] = []
        for i in 0..<MIDIGetNumberOfDevices() {
            let d = MIDIGetDevice(i)
            guard MIDIBridge.stringProperty(d, kMIDIPropertyModel) == MIDIBridge.hardwareModel else { continue }
            objs.append(d)
            for e in 0..<MIDIDeviceGetNumberOfEntities(d) {
                let en = MIDIDeviceGetEntity(d, e)
                objs.append(en)
                for s in 0..<MIDIEntityGetNumberOfSources(en) { objs.append(MIDIEntityGetSource(en, s)) }
                for s in 0..<MIDIEntityGetNumberOfDestinations(en) { objs.append(MIDIEntityGetDestination(en, s)) }
            }
        }
        return objs
    }

    private static func replace(_ dst: URL, with src: URL) throws {
        let tmp = dst.deletingLastPathComponent().appendingPathComponent(".\(dst.lastPathComponent).tmp")
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: src, to: tmp)
        if fm.fileExists(atPath: dst.path) {
            _ = try fm.replaceItemAt(dst, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dst)
        }
    }

    private static func err(_ s: String) -> NSError {
        NSError(domain: "FLX4-4Deck", code: 1, userInfo: [NSLocalizedDescriptionKey: s])
    }
}
