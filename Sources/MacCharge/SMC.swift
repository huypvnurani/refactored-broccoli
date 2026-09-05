import Foundation
import IOKit

/// Minimal AppleSMC reader for temperature sensors and fan speeds.
/// Layout mirrors the well-known SMCParamStruct used by community SMC tools.
final class SMC {
    private var conn: io_connect_t = 0
    private(set) var isOpen = false

    // Cached keys discovered on first enumeration (so refreshes stay cheap).
    private var tempKeys: [String]? = nil
    private var fanKeys: [String]? = nil

    // MARK: C structs

    private struct SMCVersion { var major: UInt8 = 0; var minor: UInt8 = 0; var build: UInt8 = 0
        var reserved: UInt8 = 0; var release: UInt16 = 0 }
    private struct SMCPLimitData { var version: UInt16 = 0; var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0; var gpuPLimit: UInt32 = 0; var memPLimit: UInt32 = 0 }
    private struct SMCKeyInfoData { var dataSize: UInt32 = 0; var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0 }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
    }

    private let kKernelIndex: UInt32 = 2
    private let kCmdReadBytes: UInt8 = 5
    private let kCmdReadKeyInfo: UInt8 = 9
    private let kCmdReadIndex: UInt8 = 8

    // MARK: Lifecycle

    func open() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let r = IOServiceOpen(service, mach_task_self_, 0, &conn)
        isOpen = (r == kIOReturnSuccess)
        return isOpen
    }

    func close() {
        if conn != 0 { IOServiceClose(conn); conn = 0 }
        isOpen = false
    }

    // MARK: Low level

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = (r << 8) | UInt32(b) }
        return r
    }
    private func keyString(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
                     UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let inSize = MemoryLayout<SMCParamStruct>.stride
        let r = IOConnectCallStructMethod(conn, kKernelIndex, &input, inSize, &output, &outSize)
        guard r == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    private func keyInfo(_ key: String) -> (size: UInt32, type: UInt32)? {
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.data8 = kCmdReadKeyInfo
        guard let out = call(&input) else { return nil }
        return (out.keyInfo.dataSize, out.keyInfo.dataType)
    }

    /// Read a key and decode into a Double according to its SMC data type.
    func readDouble(_ key: String) -> Double? {
        guard isOpen, let info = keyInfo(key), info.size > 0 else { return nil }
        var input = SMCParamStruct()
        input.key = fourCC(key)
        input.keyInfo.dataSize = info.size
        input.keyInfo.dataType = info.type
        input.data8 = kCmdReadBytes
        guard let out = call(&input) else { return nil }

        var b = [UInt8](repeating: 0, count: 32)
        withUnsafeBytes(of: out.bytes) { raw in
            for i in 0..<32 { b[i] = raw[i] }
        }
        let type = keyString(info.type)
        switch type {
        case "flt ":
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "ui8 ":
            return Double(b[0])
        case "ui16":
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "sp78":
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 256.0
        case "fpe2":
            return Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4.0
        default:
            return nil
        }
    }

    // MARK: Key enumeration

    private func keyCount() -> Int {
        guard let v = readDouble("#KEY") else { return 0 }
        return Int(v)
    }

    private func keyAtIndex(_ i: Int) -> String? {
        var input = SMCParamStruct()
        input.data8 = kCmdReadIndex
        input.data32 = UInt32(i)
        guard let out = call(&input) else { return nil }
        return keyString(out.key)
    }

    private func discoverKeys() {
        var temps: [String] = []
        var fans: [String] = []
        let count = keyCount()
        guard count > 0 else { tempKeys = []; fanKeys = []; return }
        for i in 0..<count {
            guard let k = keyAtIndex(i) else { continue }
            if k.hasPrefix("T") { temps.append(k) }
            else if k.hasPrefix("F") && (k.hasSuffix("Ac")) { fans.append(k) }
        }
        tempKeys = temps
        fanKeys = fans
    }

    // MARK: Public reads

    struct Thermal {
        var cpu: Double?      // avg of P/E-core sensors
        var gpu: Double?
        var hottest: Double?
        var sensorCount: Int = 0
    }

    /// Average CPU / GPU / peak temperature across discovered sensors (°C).
    func thermal() -> Thermal {
        if tempKeys == nil { discoverKeys() }
        guard let keys = tempKeys, !keys.isEmpty else { return Thermal() }
        var cpu: [Double] = [], gpu: [Double] = [], all: [Double] = []
        for k in keys {
            guard let v = readDouble(k), v > 5, v < 120 else { continue }
            all.append(v)
            // Tp… = performance/efficiency CPU cores, Tg… = GPU (Apple Silicon).
            if k.hasPrefix("Tp") || k.hasPrefix("Tc") || k.hasPrefix("TC") { cpu.append(v) }
            if k.hasPrefix("Tg") || k.hasPrefix("TG") { gpu.append(v) }
        }
        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0,+)/Double(a.count) }
        return Thermal(cpu: avg(cpu), gpu: avg(gpu), hottest: all.max(), sensorCount: all.count)
    }

    struct Fan: Identifiable { let id: Int; let rpm: Int; let min: Int; let max: Int }

    /// Fan speeds in RPM plus each fan's min/max range (empty on fanless Macs).
    func fans() -> [Fan] {
        if fanKeys == nil { discoverKeys() }
        let n = Int(readDouble("FNum") ?? 0)
        var result: [Fan] = []
        if n > 0 {
            for i in 0..<n {
                if let v = readDouble("F\(i)Ac"), v >= 0 {
                    let mn = Int(readDouble("F\(i)Mn") ?? 0)
                    let mx = Int(readDouble("F\(i)Mx") ?? 0)
                    result.append(Fan(id: i, rpm: Int(v), min: mn, max: mx))
                }
            }
        } else if let keys = fanKeys {
            for (i, k) in keys.enumerated() {
                if let v = readDouble(k), v >= 0 {
                    result.append(Fan(id: i, rpm: Int(v), min: 0, max: 0))
                }
            }
        }
        return result
    }
}
