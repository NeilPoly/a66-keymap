import Foundation

/// 键位表里一个键的 4 字节设备码。
///
/// `raw` 按写进键盘的字节顺序做大端表示，所以十六进制写法就是字节顺序，
/// 例如复位键 `0x07000004` = `07 00 00 04`。字节 0 是类型：
///   - `00` 普通键：字节 1 = 修饰键位图（HID 标准），字节 2 = 第二个键（一般为 0），字节 3 = 主键 HID usage
///   - `02` 多媒体：字节 2–3 = Consumer usage（大端）
///   - `07` 键盘自身功能（字节 3 = 功能号）、`08` 灯光（字节 1 = 项目，字节 2 = 加/减）
///   - `0D` Fn（字节 1 = 0）/ Fn2（字节 1 = 1）
///   - `00 00 00 00` = 无功能
public struct KeyCode: Hashable, Sendable, CustomStringConvertible {
    public let raw: UInt32

    public init(_ raw: UInt32) { self.raw = raw }

    public init(bytes b: [UInt8]) {
        precondition(b.count == 4)
        raw = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    /// 8 位十六进制（可带空格），如 "07000004" 或 "07 00 00 04"
    public init?(hex: String) {
        let h = hex.replacingOccurrences(of: " ", with: "")
        guard h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        raw = v
    }

    /// 写进键位表的 4 个字节
    public var bytes: [UInt8] { [UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)] }
    public var hex: String { String(format: "%08X", raw) }
    public var spacedHex: String { bytes.map { String(format: "%02X", $0) }.joined(separator: " ") }
    public var description: String { spacedHex }

    public var type: UInt8 { UInt8(raw >> 24) }
    public var isNone: Bool { raw == 0 }

    // MARK: 常用码

    public static let none = KeyCode(0)
    public static let fn = KeyCode(0x0D00_0000)
    public static let fn2 = KeyCode(0x0D01_0000)
    /// 出厂 Fn+CapsLock：复位键盘（会把键位清回出厂）
    public static let resetKeyboard = KeyCode(0x0700_0004)

    /// 普通键（可带修饰键），usage 为 HID 键盘页编号
    public static func key(_ usage: UInt8, mods: Modifiers = []) -> KeyCode {
        KeyCode(UInt32(mods.rawValue) << 16 | UInt32(usage))
    }

    /// 单独的修饰键
    public static func modifier(_ m: Modifiers) -> KeyCode { KeyCode(UInt32(m.rawValue) << 16) }

    /// 多媒体键（Consumer usage）
    public static func consumer(_ usage: UInt16) -> KeyCode { KeyCode(0x0200_0000 | UInt32(usage)) }

    // MARK: 拆解

    /// 类型 00 时的修饰键
    public var modifiers: Modifiers { type == 0 ? Modifiers(rawValue: UInt8((raw >> 16) & 0xFF)) : [] }
    /// 类型 00 时的主键 usage（0 = 只有修饰键）
    public var usage: UInt8 { type == 0 ? UInt8(raw & 0xFF) : 0 }
    /// 类型 00 时的第二个键（本工具不生成，导入的配置里可能有）
    public var secondUsage: UInt8 { type == 0 ? UInt8((raw >> 8) & 0xFF) : 0 }
    public var consumerUsage: UInt16? { type == 2 ? UInt16(raw & 0xFFFF) : nil }
}

/// HID 修饰键位图（字节 1）
public struct Modifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let leftControl = Modifiers(rawValue: 0x01)
    public static let leftShift = Modifiers(rawValue: 0x02)
    public static let leftOption = Modifiers(rawValue: 0x04)    // Alt
    public static let leftCommand = Modifiers(rawValue: 0x08)   // Win / GUI
    public static let rightControl = Modifiers(rawValue: 0x10)
    public static let rightShift = Modifiers(rawValue: 0x20)
    public static let rightOption = Modifiers(rawValue: 0x40)
    public static let rightCommand = Modifiers(rawValue: 0x80)

    /// 按 HID 位序排列的 8 个修饰键
    public static let all: [Modifiers] = [.leftControl, .leftShift, .leftOption, .leftCommand,
                                          .rightControl, .rightShift, .rightOption, .rightCommand]
}
