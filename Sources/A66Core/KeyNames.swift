import Foundation

// 设备码的显示名称，以及界面里可选的键（按组）。
// 键盘功能（类型 07/08）只收录 A66 出厂键位表里出现过的码，名称对照包装说明书；不提供手填任意设备码的入口。

/// 一个 HID 键：键帽上显示的短名 + 列表里的全名
struct HIDName {
    let cap: String
    let zh: String
    let en: String
}

let hidNames: [UInt8: HIDName] = {
    var m: [UInt8: HIDName] = [:]
    func put(_ u: UInt8, _ cap: String, _ zh: String? = nil, _ en: String? = nil) {
        m[u] = HIDName(cap: cap, zh: zh ?? cap, en: en ?? cap)
    }
    for i in 0..<26 { put(UInt8(0x04 + i), String(UnicodeScalar(UInt8(65 + i)))) }
    for i in 0..<9 { put(UInt8(0x1E + i), String(i + 1)) }
    put(0x27, "0")
    for i in 0..<12 { put(UInt8(0x3A + i), "F\(i + 1)") }
    put(0x28, "Enter", "回车", "Return")
    put(0x29, "Esc")
    put(0x2A, "⌫", "退格", "Backspace")
    put(0x2B, "Tab")
    put(0x2C, "Space", "空格", "Space")
    put(0x2D, "-"); put(0x2E, "="); put(0x2F, "["); put(0x30, "]"); put(0x31, "\\")
    put(0x33, ";"); put(0x34, "'"); put(0x35, "`"); put(0x36, ","); put(0x37, "."); put(0x38, "/")
    put(0x39, "Caps", "大写锁定", "Caps Lock")
    put(0x46, "PrtSc", "截屏", "Print Screen")
    put(0x47, "ScrLk", "滚动锁定", "Scroll Lock")
    put(0x48, "Pause", "暂停", "Pause")
    put(0x49, "Ins", "插入", "Insert")
    put(0x4A, "Home")
    put(0x4B, "PgUp", "上翻页", "Page Up")
    put(0x4C, "Del", "删除", "Delete")
    put(0x4D, "End")
    put(0x4E, "PgDn", "下翻页", "Page Down")
    put(0x4F, "→", "右", "Right")
    put(0x50, "←", "左", "Left")
    put(0x51, "↓", "下", "Down")
    put(0x52, "↑", "上", "Up")
    put(0x53, "Num", "数字锁定", "Num Lock")
    put(0x54, "P/", "小键盘 /", "Keypad /")
    put(0x55, "P*", "小键盘 *", "Keypad *")
    put(0x56, "P-", "小键盘 -", "Keypad -")
    put(0x57, "P+", "小键盘 +", "Keypad +")
    put(0x58, "PEnt", "小键盘回车", "Keypad Enter")
    for i in 0..<9 { put(UInt8(0x59 + i), "P\(i + 1)", "小键盘 \(i + 1)", "Keypad \(i + 1)") }
    put(0x62, "P0", "小键盘 0", "Keypad 0")
    put(0x63, "P.", "小键盘 .", "Keypad .")
    put(0x65, "Menu", "菜单", "Menu")
    return m
}()

/// 修饰键：符号、短名、全名
let modifierNames: [(Modifiers, String, String, String)] = [
    (.leftControl, "⌃", "左 Control", "Left Control"),
    (.leftShift, "⇧", "左 Shift", "Left Shift"),
    (.leftOption, "⌥", "左 Option（Alt）", "Left Option (Alt)"),
    (.leftCommand, "⌘", "左 Command（Win）", "Left Command (Win)"),
    (.rightControl, "⌃", "右 Control", "Right Control"),
    (.rightShift, "⇧", "右 Shift", "Right Shift"),
    (.rightOption, "⌥", "右 Option（Alt）", "Right Option (Alt)"),
    (.rightCommand, "⌘", "右 Command（Win）", "Right Command (Win)"),
]

let modifierShort: [String: String] = ["⌃": "Ctrl", "⇧": "Shift", "⌥": "Opt", "⌘": "Cmd"]

/// 多媒体键：Consumer usage → (键帽, 中文, 英文)
let consumerNames: [UInt16: (String, String, String)] = [
    0x00CD: ("⏯", "播放/暂停", "Play/Pause"),
    0x00B5: ("⏭", "下一曲", "Next Track"),
    0x00B6: ("⏮", "上一曲", "Previous Track"),
    0x00B7: ("⏹", "停止", "Stop"),
    0x00E2: ("Mute", "静音", "Mute"),
    0x00E9: ("Vol+", "音量 +", "Volume Up"),
    0x00EA: ("Vol−", "音量 −", "Volume Down"),
    0x006F: ("☀+", "屏幕亮度 +", "Brightness Up"),
    0x0070: ("☀−", "屏幕亮度 −", "Brightness Down"),
    0x0183: ("Player", "媒体播放器", "Media Player"),
    0x018A: ("Mail", "邮件", "Mail"),
    0x0192: ("Calc", "计算器", "Calculator"),
    0x0194: ("PC", "我的电脑", "My Computer"),
    0x0221: ("Search", "搜索", "Search"),
    0x0223: ("WWW", "浏览器主页", "Browser Home"),
    0x0224: ("Back", "浏览器后退", "Browser Back"),
    0x0225: ("Fwd", "浏览器前进", "Browser Forward"),
    0x0226: ("Stop", "浏览器停止", "Browser Stop"),
    0x0227: ("Refresh", "浏览器刷新", "Browser Refresh"),
    0x022A: ("Fav", "收藏夹", "Bookmarks"),
]

/// A66 出厂键位表里出现过的键盘功能（类型 07 / 08）
let boardFunctions: [(KeyCode, String, String, String)] = [
    (KeyCode(0x0700_0005), "BT1", "蓝牙 1（长按配对）", "Bluetooth 1 (hold to pair)"),
    (KeyCode(0x0700_0006), "BT2", "蓝牙 2（长按配对）", "Bluetooth 2 (hold to pair)"),
    (KeyCode(0x0700_0007), "BT3", "蓝牙 3（长按配对）", "Bluetooth 3 (hold to pair)"),
    (KeyCode(0x0700_0008), "2.4G", "2.4G 模式", "2.4 GHz mode"),
    (KeyCode(0x0700_0001), "Win🔒", "锁 Win 键", "Win key lock"),
    (KeyCode(0x0700_0011), "Batt", "电量查询", "Battery check"),
    (KeyCode(0x0700_000B), "LED", "背光开关", "Backlight on/off"),
    (KeyCode(0x0700_0012), "White", "一键白光", "White backlight"),
    (KeyCode(0x0800_0000), "Mode", "灯效模式切换", "Lighting mode"),
    (KeyCode(0x0802_0000), "Color", "灯光颜色切换", "Lighting color"),
    (KeyCode(0x0803_0100), "Bri+", "背光亮度 +", "Backlight brighter"),
    (KeyCode(0x0803_0200), "Bri−", "背光亮度 −", "Backlight dimmer"),
    (KeyCode(0x0804_0100), "Spd+", "灯效速度 +", "Lighting faster"),
    (KeyCode(0x0804_0200), "Spd−", "灯效速度 −", "Lighting slower"),
    (KeyCode(0x0800_0001), "LED?", "灯光功能（出厂 Fn+Space，含义未知）", "Lighting (factory Fn+Space, unknown)"),
    (KeyCode(0x0700_000A), "Fn+G", "键盘功能（出厂 Fn+G，含义未知）", "Keyboard function (factory Fn+G, unknown)"),
    (KeyCode(0x0700_0014), "Knob", "旋钮按下（出厂）", "Knob press (factory)"),
    (.resetKeyboard, "Reset", "复位键盘（长按约 5 秒，清回出厂键位）", "Reset keyboard (hold ~5 s, restores factory keymap)"),
]

extension KeyCode {
    /// 键帽上显示的短名
    public var label: String { describe(short: true) }

    /// 列表和说明里用的全名
    public var name: String { describe(short: false) }

    private func describe(short: Bool) -> String {
        if isNone { return short ? "" : L("无", "None") }
        if self == .fn { return "Fn" }
        if self == .fn2 { return "Fn2" }
        if let f = boardFunctions.first(where: { $0.0 == self }) { return short ? f.1 : L(f.2, f.3) }
        switch type {
        case 0x00:
            let mods = modifiers
            var keyNames: [String] = []
            for u in [usage, secondUsage] where u != 0 {
                if let n = hidNames[u] { keyNames.append(short ? n.cap : L(n.zh, n.en)) }
                else { keyNames.append(String(format: "HID %02X", u)) }
            }
            if keyNames.isEmpty {
                // 只有修饰键
                let ms = modifierNames.filter { mods.contains($0.0) }
                if short {
                    // 单个修饰键写成"⌘ Cmd"，右侧的加 R；多个只写符号
                    if ms.count == 1, let m = ms.first {
                        return (m.0.rawValue >= 0x10 ? "R" : "") + m.1 + " " + modifierShort[m.1]!
                    }
                    return ms.map { ($0.0.rawValue >= 0x10 ? "R" : "") + $0.1 }.joined()
                }
                return ms.map { L($0.2, $0.3) }.joined(separator: " + ")
            }
            let prefix = modifierNames.filter { mods.contains($0.0) }.map { $0.1 }.joined()
            return short ? prefix + keyNames.joined(separator: "+")
                         : (prefix.isEmpty ? "" : prefix + " ") + keyNames.joined(separator: " + ")
        case 0x02:
            let u = consumerUsage ?? 0
            if let n = consumerNames[u] { return short ? n.0 : L(n.1, n.2) }
            return short ? "Media" : String(format: L("多媒体 0x%04X", "Consumer 0x%04X"), u)
        default:
            return short ? spacedHex : L("设备码 ", "Device code ") + spacedHex
        }
    }
}

/// 界面里的一组可选键
public struct KeyGroup: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let codes: [KeyCode]
    /// 这一组的键能不能加修饰键做成组合键
    public let allowsModifiers: Bool
}

public enum KeyCatalog {
    public static var groups: [KeyGroup] {
        let letters = (0x04...0x1D).map { KeyCode.key(UInt8($0)) } + (0x1E...0x27).map { KeyCode.key(UInt8($0)) }
        let symbols: [UInt8] = [0x35, 0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x36, 0x37, 0x38,
                                0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x39]
        let nav: [UInt8] = [0x50, 0x52, 0x51, 0x4F, 0x4A, 0x4D, 0x4B, 0x4E, 0x4C, 0x49]
        let fkeys: [UInt8] = Array(0x3A...0x45) + [0x46, 0x47, 0x48, 0x65]
        let keypad: [UInt8] = [0x53, 0x54, 0x55, 0x56, 0x57, 0x58] + Array(0x59...0x63)
        let mods = Modifiers.all.map { KeyCode.modifier($0) } + [KeyCode.fn]
        let media: [UInt16] = [0x00CD, 0x00B6, 0x00B5, 0x00B7, 0x00E2, 0x00EA, 0x00E9, 0x0070, 0x006F,
                               0x0183, 0x018A, 0x0192, 0x0194, 0x0221, 0x0223, 0x0224, 0x0225, 0x0226, 0x0227, 0x022A]
        return [
            KeyGroup(id: "letters", title: L("字母数字", "Letters"), codes: letters, allowsModifiers: true),
            KeyGroup(id: "symbols", title: L("符号编辑", "Symbols"), codes: symbols.map { .key($0) }, allowsModifiers: true),
            KeyGroup(id: "nav", title: L("方向导航", "Navigation"), codes: nav.map { .key($0) }, allowsModifiers: true),
            KeyGroup(id: "fkeys", title: L("F 键", "F-keys"), codes: fkeys.map { .key($0) }, allowsModifiers: true),
            KeyGroup(id: "mods", title: L("修饰键", "Modifiers"), codes: mods, allowsModifiers: false),
            KeyGroup(id: "media", title: L("多媒体", "Media"), codes: media.map { .consumer($0) }, allowsModifiers: false),
            KeyGroup(id: "board", title: L("键盘功能", "Keyboard"), codes: boardFunctions.map { $0.0 }, allowsModifiers: false),
            KeyGroup(id: "keypad", title: L("小键盘", "Keypad"), codes: keypad.map { .key($0) }, allowsModifiers: true),
        ]
    }

    /// 命令行写法 → 设备码。认：修饰键名（LCtrl/LShift/LAlt/LOpt/LWin/LCmd/LGUI 及 R 开头的）、Fn、键名（A、F5、Home、Left…）、
    /// 用 + 连接的组合（LCmd+Left）、raw:8 位十六进制。
    public static func code(forSpec spec: String) -> KeyCode? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("raw:") { return KeyCode(hex: String(s.dropFirst(4))) }
        let lower = s.lowercased()
        if lower == "fn" { return .fn }
        if lower == "none" || lower == "empty" { return KeyCode.none }
        var mods: Modifiers = []
        var usage: UInt8 = 0
        for part in s.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) {
            if let m = modifierAliases[part] { mods.insert(m); continue }
            guard usage == 0, let u = usageForName(part) else { return nil }
            usage = u
        }
        if usage == 0 && mods.isEmpty { return nil }
        return .key(usage, mods: mods)
    }

    static let modifierAliases: [String: Modifiers] = {
        var m: [String: Modifiers] = [:]
        for (side, prefix) in [("left", "l"), ("right", "r")] {
            let isLeft = side == "left"
            for n in ["ctrl", "control"] { m[prefix + n] = isLeft ? .leftControl : .rightControl }
            for n in ["shift"] { m[prefix + n] = isLeft ? .leftShift : .rightShift }
            for n in ["alt", "opt", "option"] { m[prefix + n] = isLeft ? .leftOption : .rightOption }
            for n in ["win", "cmd", "command", "gui"] { m[prefix + n] = isLeft ? .leftCommand : .rightCommand }
        }
        return m
    }()

    static func usageForName(_ name: String) -> UInt8? {
        let aliases: [String: UInt8] = [
            "enter": 0x28, "return": 0x28, "esc": 0x29, "escape": 0x29, "backspace": 0x2A, "tab": 0x2B,
            "space": 0x2C, "capslock": 0x39, "caps": 0x39, "delete": 0x4C, "del": 0x4C, "insert": 0x49,
            "pageup": 0x4B, "pgup": 0x4B, "pagedown": 0x4E, "pgdn": 0x4E, "home": 0x4A, "end": 0x4D,
            "left": 0x50, "right": 0x4F, "up": 0x52, "down": 0x51, "menu": 0x65, "prtsc": 0x46,
            "printscreen": 0x46, "scrolllock": 0x47, "pause": 0x48, "grave": 0x35, "minus": 0x2D, "equal": 0x2E,
        ]
        if let u = aliases[name] { return u }
        return hidNames.first { $0.value.cap.lowercased() == name && $0.key < 0x53 }?.key
    }
}
