import Foundation

// 导入原厂 Windows 驱动保存的键位配置 profile.dct
// （位置：%LOCALAPPDATA%\BYCOMBO4\A66 Keyboard\profile.dct）。
// 键记录 → 设备码的换算逐条对照原驱动的 keyinfo_to_hardware_code 行为实现。

/// profile.dct 里的一条键记录（16 字节）：
///   u32 (Major<<24 | Minor), u8 修饰位图, u8 VK1, u8 VK2, u8 原始VK, u32 参数, u8 灯号, u8 矩阵号, u16 保留
struct KeyRecord {
    var word0: UInt32
    var mods: UInt8
    var vk1: UInt8
    var vk2: UInt8
    var param: UInt32

    var major: UInt8 { UInt8(word0 >> 24) }
    var minor: UInt32 { word0 & 0xFFFFFF }
    /// 原驱动只看第一个 u32 是否为 0 来决定跳过
    var isEmpty: Bool { word0 == 0 }

    init(bytes b: ArraySlice<UInt8>) {
        let s = b.startIndex
        func u32(_ o: Int) -> UInt32 {
            UInt32(b[s + o]) | UInt32(b[s + o + 1]) << 8 | UInt32(b[s + o + 2]) << 16 | UInt32(b[s + o + 3]) << 24
        }
        word0 = u32(0)
        mods = b[s + 4]; vk1 = b[s + 5]; vk2 = b[s + 6]
        param = u32(8)
    }
}

public enum WindowsImportError: Error, CustomStringConvertible {
    case tooShort(Int, Int)
    case unsupported(layer: Int, key: Int, what: String)

    public var description: String {
        switch self {
        case let .tooShort(have, need):
            return L("profile.dct 太短：\(have) 字节，至少要 \(need)", "profile.dct is too short: \(have) bytes, need at least \(need)")
        case let .unsupported(l, k, what):
            return L("第 \(l) 层 K\(k)：\(what)", "Layer \(l) K\(k): \(what)")
        }
    }
}

extension Keymap {
    /// profile.dct：偏移 0x3C 起 4 层 × 144 条 × 16 字节，第 i 条对应 K(i+1)。只取前 3 层的 K1…K67。
    public init(windowsProfile data: Data) throws {
        let base = 0x3C, layerCount = 4, perLayer = 0x90, size = 16
        let d = [UInt8](data)
        let need = base + layerCount * perLayer * size
        guard d.count >= need else { throw WindowsImportError.tooShort(d.count, need) }
        self.init()
        for l in 0..<Keymap.layerCount {
            for i in 0..<perLayer {
                let o = base + (l * perLayer + i) * size
                let r = KeyRecord(bytes: d[o..<o + size])
                if r.isEmpty { continue }
                guard i < A66Layout.keys.count else {
                    throw WindowsImportError.unsupported(layer: l, key: i + 1, what: L("A66 没有这个键", "A66 has no such key"))
                }
                let code: UInt32
                do { code = try windowsHardwareCode(for: r) } catch {
                    throw WindowsImportError.unsupported(layer: l, key: i + 1, what: "\(error)")
                }
                // 原驱动的结果按小端写进键位表，换成字节顺序
                layers[l][i + 1] = KeyCode(code.byteSwapped)
            }
        }
    }
}

// MARK: - 键记录 → 设备码（原驱动的 32 位整数形式，写进键位表时按小端存放）

enum KeyRecordError: Error, CustomStringConvertible {
    case macroUnsupported
    case unknown(major: UInt8, minor: UInt32)

    var description: String {
        switch self {
        case .macroUnsupported: return L("宏暂不支持", "macros are not supported")
        case let .unknown(major, minor): return String(format: L("无法换算：Major=%d Minor=0x%X", "cannot convert: Major=%d Minor=0x%X"), major, minor)
        }
    }
}

func windowsHardwareCode(for r: KeyRecord) throws -> UInt32 {
    let major = r.major
    let minor = r.minor
    switch major {
    case 1:
        let t: [UInt32: UInt32] = [
            0x11: 0x10101, 0x12: 0x10301, 0x13: 0x10201, 0x14: 0x10401, 0x15: 0x10501,
            0x16: 0x20101, 0x17: 0x30101, 0x19: 0x801, 0x1A: 0x901,
            0x1B: 0x32FF0701, 0x1C: 0x32FF0601,
        ]
        if let v = t[minor] { return v }
    case 3, 4:
        if let v = consumerByMinor[minor] { return v }
    case 2:
        let mods = r.mods, vk1 = r.vk1
        if mods == 0 {
            if vk1 == 0xFA { return 0x0D }   // Fn
            if vk1 == 0xFB { return 0x10D }  // Fn2
        }
        if vk1 >= 1 && vk1 <= 5 {            // 鼠标键 VK：原样用参数
            return r.param
        }
        if let v = consumerByVK[vk1] { return v }
        let h2 = UInt32(hidUsage(forVK: r.vk2))
        let h1 = UInt32(hidUsage(forVK: vk1))
        return (h1 << 24) | (h2 << 16) | (UInt32(mods) << 8)
    case 5:
        throw KeyRecordError.macroUnsupported
    case 6:
        let t: [UInt32: UInt32] = [
            0x43: 0x1D0100, 0x48: 0x160100, 0x51: 0x3D0400, 0x52: 0xF0800, 0x54: 0x150800,
            0x55: 0x70800, 0x56: 0x2E0100, 0x57: 0x2D0100, 0x5A: 0x4C0500,
            0x60: 0x7, 0x61: 0x1000007, 0x62: 0x2000007, 0x63: 0x4000007,
            0x64: 0x2000010, 0x65: 0x4000010,
            0x66: 0x7000005, 0x67: 0x7000006, 0x68: 0x7000007, 0x69: 0x7000008, 0x6A: 0x7000009,
            0xA2: 0,
        ]
        if let v = t[minor] { return v }
    case 8:
        switch minor {
        case 0xA2, 0xA7: return 0
        case 0xA4:
            // 取参数的第 3 个字节选灯效档位
            let sel = UInt8((r.param >> 16) & 0xFF)
            var lo: UInt32 = 0, b1: UInt32 = 0
            if sel >= 0xF0 && sel <= 0xF4 { lo = 1; b1 = UInt32(sel - 0xF0 + 1) }
            return ((((r.param >> 8) & 0xFF) << 8 | (r.param & 0xFF)) << 8 | b1) << 8 | lo
        case 0xA6: return (r.param &- 1) &* 0x1000000 | 0x505
        case 0xA8: return 0x105
        case 0xA9: return 0x205
        case 0xAA: return 0x405
        case 0xAB: return 6
        case 0xAD: return r.param
        case 0xAE: return 8
        default: break
        }
    case 9:
        // 按字节顺序书写的设备码：minor≠0 时整字反转字节序，minor=0 原样
        return minor != 0 ? r.param.byteSwapped : r.param
    default:
        break
    }
    throw KeyRecordError.unknown(major: major, minor: minor)
}

/// Major 3/4 的多媒体码（同一张表也被 Major 2 的自定义 VK 0x88–0x8F、0x99–0x9B 复用）
private let consumerByMinor: [UInt32: UInt32] = [
    0x21: 0x83010002, 0x22: 0xCD000002, 0x23: 0xB7000002, 0x24: 0xB6000002, 0x25: 0xB5000002,
    0x26: 0xE9000002, 0x27: 0xEA000002, 0x28: 0xE2000002, 0x29: 0x6F000002, 0x2A: 0x70000002,
    0x30: 0x8A010002, 0x31: 0x92010002, 0x32: 0x94010002, 0x33: 0x21020002, 0x34: 0x23020002,
    0x35: 0x24020002, 0x36: 0x25020002, 0x37: 0x26020002, 0x38: 0x27020002, 0x39: 0x2A020002,
]

private let consumerByVK: [UInt8: UInt32] = [
    0x88: 0x83010002, 0x89: 0xCD000002, 0x8A: 0xB7000002, 0x8B: 0xB6000002, 0x8C: 0xB5000002,
    0x8D: 0xE9000002, 0x8E: 0xEA000002, 0x8F: 0xE2000002,
    0x99: 0x92010002, 0x9A: 0x94010002, 0x9B: 0x23020002,
]

func hidUsage(forVK vk: UInt8) -> UInt8 {
    for p in vkToHIDTable where p.vk == vk { return p.hid }
    return 0
}

/// Windows 虚拟键码 → HID usage（112 对，按 VK 顺序查第一个匹配，找不到为 0）
private let vkToHIDTable: [(hid: UInt8, vk: UInt8)] = [
    (0x64, 0xE2), (0x29, 0x1B), (0x3A, 0x70), (0x3B, 0x71), (0x3C, 0x72), (0x3D, 0x73), (0x3E, 0x74), (0x3F, 0x75),
    (0x40, 0x76), (0x41, 0x77), (0x42, 0x78), (0x43, 0x79), (0x44, 0x7A), (0x45, 0x7B), (0x04, 0x41), (0x05, 0x42),
    (0x06, 0x43), (0x07, 0x44), (0x08, 0x45), (0x09, 0x46), (0x0A, 0x47), (0x0B, 0x48), (0x0C, 0x49), (0x0D, 0x4A),
    (0x0E, 0x4B), (0x0F, 0x4C), (0x10, 0x4D), (0x11, 0x4E), (0x12, 0x4F), (0x13, 0x50), (0x14, 0x51), (0x15, 0x52),
    (0x16, 0x53), (0x17, 0x54), (0x18, 0x55), (0x19, 0x56), (0x1A, 0x57), (0x1B, 0x58), (0x1C, 0x59), (0x1D, 0x5A),
    (0x1E, 0x31), (0x1F, 0x32), (0x20, 0x33), (0x21, 0x34), (0x22, 0x35), (0x23, 0x36), (0x24, 0x37), (0x25, 0x38),
    (0x26, 0x39), (0x27, 0x30), (0x2B, 0x09), (0x39, 0x14), (0x28, 0x0D), (0x2A, 0x08), (0x2C, 0x20), (0x2F, 0xDB),
    (0x30, 0xDD), (0x31, 0xDC), (0x33, 0xBA), (0x34, 0xDE), (0x36, 0xBC), (0x37, 0xBE), (0x38, 0xBF), (0x35, 0xC0),
    (0x2E, 0xBB), (0x2D, 0xBD), (0x46, 0x2C), (0x47, 0x91), (0x48, 0x13), (0x49, 0x2D), (0x4A, 0x24), (0x4B, 0x21),
    (0x4C, 0x2E), (0x4D, 0x23), (0x4E, 0x22), (0x52, 0x26), (0x51, 0x28), (0x50, 0x25), (0x4F, 0x27), (0x59, 0x61),
    (0x5A, 0x62), (0x5B, 0x63), (0x5C, 0x64), (0x5D, 0x65), (0x5E, 0x66), (0x5F, 0x67), (0x60, 0x68), (0x61, 0x69),
    (0x62, 0x60), (0x57, 0x6B), (0x56, 0x6D), (0x55, 0x6A), (0x54, 0x6F), (0x53, 0x90), (0x58, 0xFD), (0x63, 0x6E),
    (0xE0, 0xA2), (0xE1, 0xA0), (0xE2, 0xA4), (0xE3, 0x5B), (0xE4, 0xA3), (0xE5, 0xA1), (0xE6, 0xA5), (0xE7, 0x5C),
    (0x65, 0x5D), (0x85, 0xC2), (0x87, 0xC1), (0x89, 0xC3), (0x32, 0xD8), (0x8A, 0xDA), (0x88, 0xD7), (0x8B, 0xEB),
]
