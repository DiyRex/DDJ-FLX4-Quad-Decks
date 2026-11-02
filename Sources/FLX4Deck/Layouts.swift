import Foundation

/// Swaps rekordbox's FLX4 user mapping between your normal 2-channel layout and the
/// generated 4-deck layout. The 2-channel file is backed up byte-for-byte and put back
/// whenever 4-deck mode ends; rekordbox's bundled default is never touched.
enum Layouts {
    static let fm = FileManager.default
    static let home = fm.homeDirectoryForCurrentUser

    static var rbDir: URL { home.appendingPathComponent("Library/Application Support/Pioneer/rekordbox6/MidiMappings") }
    static var flxFile: URL { rbDir.appendingPathComponent("DDJ-FLX4.midi.csv") }
    static var virtualFile: URL { rbDir.appendingPathComponent("\(MIDIBridge.virtualName).midi.csv") }

    static var stateDir: URL { home.appendingPathComponent("Library/Application Support/FLX4-4Deck") }
    static var backupFile: URL { stateDir.appendingPathComponent("DDJ-FLX4.2channel-backup.midi.csv") }
    static var noOriginalFlag: URL { stateDir.appendingPathComponent("no-original-mapping") }

    static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "mappings")
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("../../../Resources/mappings/\(name).csv").standardized
    }

    /// rekordbox rewrites mapping files and drops comment rows, so install state is kept
    /// in our own flag file rather than inside the CSV.
    static var installedFlag: URL { stateDir.appendingPathComponent("4deck-installed") }
    static var is4DeckInstalled: Bool { fm.fileExists(atPath: installedFlag.path) }

    static func install4Deck() throws {
        guard let flx = bundled("DDJ-FLX4.4deck.midi"), let virt = bundled("\(MIDIBridge.virtualName).midi"),
              fm.fileExists(atPath: flx.path), fm.fileExists(atPath: virt.path) else {
            throw err("4-deck mapping files are missing from the app bundle")
        }
        try fm.createDirectory(at: rbDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        if !is4DeckInstalled {  // only ever back up a genuine 2-channel file
            if fm.fileExists(atPath: flxFile.path) {
                try replace(backupFile, with: flxFile)
                try? fm.removeItem(at: noOriginalFlag)
            } else {
                fm.createFile(atPath: noOriginalFlag.path, contents: nil)
            }
        }
        try replace(flxFile, with: flx)
        try replace(virtualFile, with: virt)
        fm.createFile(atPath: installedFlag.path, contents: nil)
    }

    static func restore2Channel() throws {
        if is4DeckInstalled {
            if fm.fileExists(atPath: backupFile.path) {
                try replace(flxFile, with: backupFile)
            } else if fm.fileExists(atPath: noOriginalFlag.path) {
                try fm.removeItem(at: flxFile)
            } else {
                // No backup recorded: fall back to rekordbox's "use default" stub.
                try "@file,1,DDJ-FLX4\r\n".write(to: flxFile, atomically: true, encoding: .utf8)
            }
        }
        if fm.fileExists(atPath: virtualFile.path) { try fm.removeItem(at: virtualFile) }
        try? fm.removeItem(at: installedFlag)
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
