import Foundation
import SMCCore

// maccharge-fanhelper — the privileged half of MacCharge's fan control.
//
// The SMC accepts fan writes only from root, so MacCharge installs this tool
// setuid-root (once, behind an admin prompt) and shells out to it. Everything it
// can do is in the switch below: report fan state, force a fan to an RPM inside
// the range the firmware itself reports, or hand a fan back to automatic
// control. It never writes any SMC key other than F<n>Md / F<n>Tg (or, on Intel
// Macs without a T2 chip, the "FS! " force mask), never reads
// stdin, and never invokes a shell — a setuid binary with a wider reach would be
// a local privilege-escalation tool.

let version = "2"

func die(_ message: String, _ code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("maccharge-fanhelper: " + message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    die("""
        usage:
          maccharge-fanhelper status            # JSON description of every fan
          maccharge-fanhelper set <fan> <rpm>   # hold <fan> at <rpm> (root)
          maccharge-fanhelper auto [<fan>]      # back to automatic (root)
          maccharge-fanhelper version
        """, 64)
}

/// A setuid copy starts with euid 0 but the caller's real uid; making both root
/// keeps the IOKit privilege check predictable. (macOS already strips DYLD_* and
/// friends from setuid processes, so there is nothing to sanitise here.)
func becomeRoot() {
    guard geteuid() == 0 else {
        die("not running as root — reinstall the helper from MacCharge ▸ Cooling", 77)
    }
    setuid(0)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
if command == "version" { print(version); exit(0) }

let smc = SMC()
guard smc.open() else { die("cannot open the AppleSMC service", 70) }
defer { smc.close() }

let fans = smc.fans()
guard !fans.isEmpty else { die("this Mac reports no fans", 69) }

/// Parse a fan index that actually exists on this machine.
func fanArgument(_ raw: String) -> SMC.Fan {
    guard let i = Int(raw), let fan = fans.first(where: { $0.id == i }) else {
        die("no such fan: \(raw) (this Mac has \(fans.count))", 65)
    }
    return fan
}

switch command {
case "status":
    let payload: [String: Any] = [
        "version": version,
        "root": geteuid() == 0,
        "fans": fans.map { [
            "id": $0.id, "rpm": $0.rpm, "min": $0.min, "max": $0.max,
            "target": $0.target, "forced": $0.forced,
        ] },
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: payload),
          let text = String(data: json, encoding: .utf8) else { die("cannot encode status", 70) }
    print(text)

case "set":
    guard args.count == 3, let requested = Int(args[2]) else { usage() }
    let fan = fanArgument(args[1])
    guard fan.isControllable else { die("fan \(fan.id) reports no usable range", 69) }
    becomeRoot()
    // The firmware's own minimum is the floor: a slider must never be able to
    // stop a fan that the hardware wants spinning.
    let rpm = Swift.min(Swift.max(requested, fan.min), fan.max)
    guard smc.forceFan(fan.id, rpm: rpm) else {
        die(smc.lastFailureWasPrivilege
            ? "the SMC refused the write (not privileged)"
            : "the SMC refused to set fan \(fan.id) to \(rpm) RPM", 71)
    }
    print(rpm)

case "auto":
    becomeRoot()
    let targets = args.count > 1 ? [fanArgument(args[1])] : fans
    var failed: [Int] = []
    for fan in targets where !smc.releaseFan(fan.id) { failed.append(fan.id) }
    guard failed.isEmpty else {
        die("the SMC refused to release fan(s) \(failed.map(String.init).joined(separator: ", "))", 71)
    }
    print("auto")

default:
    usage()
}
