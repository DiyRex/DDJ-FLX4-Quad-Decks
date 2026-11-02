import AppKit

let args = CommandLine.arguments

if args.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

if args.contains("--sniff") || args.contains("--headless") {
    // Router without UI. --sniff prints every message in and out.
    Log.echo = true
    let bridge = MIDIBridge()
    bridge.verbose = args.contains("--sniff")
    bridge.log = { Log.write($0) }
    do { try bridge.start() } catch { print(error.localizedDescription); exit(1) }
    Log.write("headless router running; virtual device \(MIDIBridge.virtualName). Ctrl-C to stop.")
    signal(SIGINT) { _ in exit(0) }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
