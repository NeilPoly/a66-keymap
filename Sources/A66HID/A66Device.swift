import A66Core
import Foundation
import IOKit.hid

// 与键盘通信：找配置通道、读密码核对型号、读写键位表。
// 只用 WiredPacket / WirelessPacket 里登记过的命令。所有调用都是阻塞的（以前的 app 放在后台线程跑；命令行直接调用）。

public enum A66 {
    public static let wiredVID = 0x258A
    public static let wiredPID = 0x010C
    public static let wirelessVID = 0x3554
    /// 读到的"密码"必须是这 6 个字节才写入（同 VID/PID 被多家品牌的键盘共用）
    public static let password: [UInt8] = [0x03, 0x00, 0x00, 0x00, 0x00, 0xD9]
}

public enum Connection: String, Sendable {
    case wired, bluetooth, receiver

    public var title: String {
        switch self {
        case .wired: return L("有线", "USB cable")
        case .bluetooth: return L("蓝牙", "Bluetooth")
        case .receiver: return L("2.4G 接收器", "2.4 GHz receiver")
        }
    }
}

/// 找到的一个配置通道（只枚举，没打开）
public struct ConfigChannel: Identifiable {
    public let info: HIDDeviceInfo
    public let connection: Connection
    public var id: String { "\(connection.rawValue)-\(info.locationID)-\(info.productID)" }
}

public struct A66Error: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum A66Device {
    /// 列出当前能看到的配置通道：有线在前，然后蓝牙、2.4G
    public static func channels() -> [ConfigChannel] {
        HID.enumerate(vendorIDs: [A66.wiredVID, A66.wirelessVID]).compactMap { d in
            if d.vendorID == A66.wiredVID && d.productID == A66.wiredPID && d.has(page: 0xFF00, usage: 1)
                && d.maxFeature == WiredPacket.size {
                return ConfigChannel(info: d, connection: .wired)
            }
            if d.vendorID == A66.wirelessVID && d.has(page: 0xFF02, usage: 2) && d.maxOutput >= WirelessPacket.size {
                return ConfigChannel(info: d, connection: d.transport.lowercased().contains("bluetooth") ? .bluetooth : .receiver)
            }
            return nil
        }
        .sorted { order($0.connection) < order($1.connection) }
    }

    private static func order(_ c: Connection) -> Int { c == .wired ? 0 : c == .bluetooth ? 1 : 2 }

    /// 打开通道。三种连接都需要"输入监控"权限：配置通道和键盘集合在同一个接口里，
    /// IOKit 给整个接口标了 RequiresTCCAuthorization。蓝牙 / 2.4G 先检查权限，没有时触发系统授权提示并报错；
    /// 有线在系统拒绝打开（not permitted）时再去请求授权。
    public static func open(_ ch: ConfigChannel, log: @escaping (String) -> Void = { _ in }) throws -> A66Link {
        switch ch.connection {
        case .wired:
            let f = FeatureChannel(ch.info)
            do { try f.open() } catch {
                if let e = error as? HIDError, UInt32(bitPattern: e.code) == 0xE00002E2, !hasInputMonitoring() {
                    throw A66Error(permissionMessage)
                }
                throw A66Error("\(error)")
            }
            return WiredLink(f, log: log)
        case .bluetooth, .receiver:
            guard hasInputMonitoring() else { throw A66Error(permissionMessage) }
            let r = ReportChannel(ch.info, reportID: WirelessPacket.reportID)
            do { try r.open() } catch {
                var msg = "\(error)"
                if ch.connection == .bluetooth {
                    msg += "\n" + L("蓝牙下配置通道和键盘本体是同一个设备，Karabiner-Elements 接管键盘时会独占。在 Karabiner 设置 → Devices 里临时关掉这把键盘的 Modify events，改完再打开。",
                                    "Over Bluetooth the config channel is the keyboard itself; if Karabiner-Elements grabs it, temporarily turn off Modify events for this keyboard in Karabiner → Devices.")
                }
                throw A66Error(msg)
            }
            return WirelessLink(r, connection: ch.connection, log: log)
        }
    }

    /// 有没有"输入监控"权限；没有时请求一次（第一次会弹出系统授权框）
    static func hasInputMonitoring() -> Bool {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted { return true }
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        return IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static let permissionMessage = L(
        "需要“输入监控”权限：系统设置 → 隐私与安全性 → 输入监控，打开你用的终端，然后完全退出终端再打开，重试。",
        "Input Monitoring permission is needed: System Settings → Privacy & Security → Input Monitoring, enable your terminal app, then quit and reopen it and try again.")

    /// 该用哪个通道：有线 > 蓝牙 > 2.4G 的第一个。有线、蓝牙的通道只在键盘处于该模式时才出现，
    /// 接收器插着却不代表键盘在 2.4G 模式，所以只要有更高优先级的通道就不用接收器；
    /// 也不在失败后退到下一个（比如蓝牙被 Karabiner 独占时退到接收器只会白等），直接报真实原因。
    public static func preferred(_ channels: [ConfigChannel]) -> ConfigChannel? { channels.first }

    /// 打开通道并读密码（只读）。cancel 可在等待键盘应答时中止。
    public static func connect(_ ch: ConfigChannel, cancel: CancelFlag? = nil,
                               log: @escaping (String) -> Void = { _ in }) throws -> (link: A66Link, password: [UInt8]) {
        let link = try open(ch, log: log)
        do {
            return (link, try link.readPassword(cancel: cancel))
        } catch {
            link.close()
            throw error
        }
    }

    /// 能不能读键位。蓝牙不行：键盘约每 4 ms 发一包回包，蓝牙连接每 15 ms 只送得出 1–2 包，
    /// 其余被键盘丢掉，而且总是丢同样的位置，多读几次也凑不齐（2026-11-03 实测，见 docs/protocol.md）
    public static func canRead(_ c: Connection) -> Bool { c != .bluetooth }

    public static let bluetoothReadMessage = L(
        "蓝牙下读不了键位：键盘发回数据太快，蓝牙一次只送得出一小部分，读不全。请插线（拨到有线）或用 2.4G 接收器读取。",
        "The keymap cannot be read over Bluetooth: the keyboard sends its reply faster than Bluetooth can carry it, so most of it is lost. Read it by cable (wired mode) or through the 2.4 GHz receiver.")

    /// 写入后读回核对的结果
    public enum Verification: Equatable, Sendable {
        /// 读回的内容与写入的一致
        case verified
        /// 写入每包都有应答，但读回失败，没能核对（附原因）
        case unverified(String)
    }

    /// 核对密码后写入指定层，写完把这些层读回来逐字节核对。只有连接、读密码阶段能取消；开始写以后不响应取消，免得写一半。
    /// progress(已完成包数, 总包数)，开始写时先报 (0, 总数)。读回与写入不一致时抛错。
    @discardableResult
    public static func write(_ keymap: Keymap, layers: [Int], to ch: ConfigChannel, cancel: CancelFlag? = nil,
                             log: @escaping (String) -> Void = { _ in },
                             progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> Verification {
        precondition(!layers.isEmpty && layers.allSatisfy { (0..<Keymap.layerCount).contains($0) })
        let (link, psd) = try connect(ch, cancel: cancel, log: log)
        defer { link.close() }
        try checkPassword(psd, ch: ch, log: log)
        try link.writeLayers(layers.map { ($0, keymap.matrix(layer: $0)) }, progress: progress)

        guard canRead(ch.connection) else {
            let why = L("蓝牙下读不回完整数据，没法核对；写入时每包都有键盘应答。",
                        "Bluetooth cannot read back complete data, so the write was not verified; every packet was acknowledged.")
            log("  " + why)
            return .unverified(why)
        }

        // 读回核对。刚写完时先稍等；不一致再等一会儿重读一次，免得键盘还没存完就误报
        log(L("  读回核对…", "  verifying by reading back…"))
        var mismatched = layers
        for wait: UInt32 in [100, 400] where !mismatched.isEmpty {
            msleep(wait)
            let back: [[UInt8]]
            do { back = try link.readLayers(mismatched, progress: { _, _ in }) } catch {
                log(L("  ⚠ 读回失败，没能核对：\(error)", "  ⚠ could not read back to verify: \(error)"))
                return .unverified("\(error)")
            }
            mismatched = zip(mismatched, back).filter { !keymap.matches($0.1, layer: $0.0) }.map(\.0)
        }
        guard mismatched.isEmpty else {
            throw A66Error(L("写入后读回核对不一致（\(mismatched.map { "第 \($0) 层" }.joined(separator: "、"))）。键盘里可能是新旧混合的状态，请重新写一次。",
                             "Read-back after writing does not match (layer \(mismatched.map(String.init).joined(separator: ", "))). The keyboard may be half-updated; write again."))
        }
        log(L("  ✓ 读回核对一致", "  ✓ read-back matches"))
        return .verified
    }

    /// 核对密码后读回 0–2 层，组成配置（只读）。unknown = 不在 A66 键位排列上却有内容的位置。
    /// progress(已读层数, 总层数)。只有连接、读密码阶段能取消。
    public static func readKeymap(from ch: ConfigChannel, cancel: CancelFlag? = nil,
                                  log: @escaping (String) -> Void = { _ in },
                                  progress: @escaping (Int, Int) -> Void = { _, _ in }) throws -> (keymap: Keymap, unknown: [Keymap.UnknownEntry]) {
        guard canRead(ch.connection) else { throw A66Error(bluetoothReadMessage) }
        let (link, psd) = try connect(ch, cancel: cancel, log: log)
        defer { link.close() }
        try checkPassword(psd, ch: ch, log: log)
        let ms = try link.readLayers(Array(0..<Keymap.layerCount), progress: progress)
        log(L("  ✓ 已读回 3 层", "  ✓ read 3 layers"))
        return Keymap.fromMatrices(ms)
    }

    private static func checkPassword(_ psd: [UInt8], ch: ConfigChannel, log: (String) -> Void) throws {
        guard psd == A66.password else {
            throw A66Error(L("键盘密码 \(hex(psd)) 不是 A66 的 \(hex(A66.password))，已中止，没有读写任何东西。",
                             "Keyboard ID \(hex(psd)) is not the A66's \(hex(A66.password)); aborted, nothing was read or written."))
        }
        log(L("✓ 型号核对通过（\(ch.connection.title)，\(hex(psd))）", "✓ Keyboard ID verified (\(ch.connection.title), \(hex(psd)))"))
    }
}

/// 跨线程的取消标记
public final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// 打开后的配置通道
public protocol A66Link: AnyObject {
    var connection: Connection { get }
    /// 读 6 字节密码（只读）
    func readPassword(cancel: CancelFlag?) throws -> [UInt8]
    /// 写若干层的 512 字节键位表
    func writeLayers(_ layers: [(Int, [UInt8])], progress: @escaping (Int, Int) -> Void) throws
    /// 读回若干层的键位表（有线 512 字节，无线 504 字节），progress(已读层数, 总层数)
    func readLayers(_ layers: [Int], progress: @escaping (Int, Int) -> Void) throws -> [[UInt8]]
    func close()
}

extension A66Link {
    public func readPassword() throws -> [UInt8] { try readPassword(cancel: nil) }
}

func msleep(_ ms: UInt32) { usleep(ms * 1000) }

// MARK: - 有线：Feature 报告 6，520 字节

final class WiredLink: A66Link {
    let ch: FeatureChannel
    let log: (String) -> Void
    var connection: Connection { .wired }

    init(_ ch: FeatureChannel, log: @escaping (String) -> Void) { self.ch = ch; self.log = log }

    func close() { ch.close() }

    /// SetFeature，失败隔 70ms 重试，共 3 次
    private func send(_ pkt: [UInt8]) throws {
        var lastErr: Error?
        for attempt in 1...3 {
            do { try ch.setFeature(pkt); return } catch {
                lastErr = error
                log(L("  第 \(attempt) 次发送失败：\(error)", "  send attempt \(attempt) failed: \(error)"))
                msleep(70)
            }
        }
        throw A66Error("\(lastErr!)")
    }

    /// 等 20ms → 发读请求（只有包头）→ 等 20ms → 取回，数据从偏移 8 起
    func readPassword(cancel: CancelFlag?) throws -> [UInt8] {
        msleep(20)
        try send(WiredPacket.readRequest(.readPassword, sub: 1, length: 6))
        msleep(20)
        let rsp: [UInt8]
        do { rsp = try ch.getFeature(reportID: WiredPacket.reportID, length: WiredPacket.size) } catch { throw A66Error("\(error)") }
        guard rsp.count >= 14 else { throw A66Error(L("回包太短：", "Reply too short: ") + hex(rsp)) }
        return Array(rsp[8..<14])
    }

    /// 每包前等 20ms，每层之后等 30ms
    func writeLayers(_ layers: [(Int, [UInt8])], progress: @escaping (Int, Int) -> Void) throws {
        let all = layers.map { (l, m) in (l, WiredPacket.packets(.setMatrix, sub: UInt8(l), data: m)) }
        let total = all.reduce(0) { $0 + $1.1.count }
        var done = 0
        progress(0, total)
        for (l, pkts) in all {
            for (i, p) in pkts.enumerated() {
                msleep(20)
                do { try send(p) } catch {
                    throw A66Error(L("第 \(l) 层第 \(i) 包写入失败：\(error)。键盘可能处于新旧混合状态，重新写一次即可。",
                                     "Writing layer \(l) packet \(i) failed: \(error). The keyboard may be half-updated; just write again."))
                }
                done += 1
                progress(done, total)
            }
            log(L("  第 \(l) 层已写入", "  layer \(l) written"))
            msleep(30)
        }
    }

    /// 每层：等 20ms → 发读请求 0x83（只有包头）→ 等 20ms → 取回。包头回显和末尾 5A A5 对不上就重读，最多 3 次
    func readLayers(_ layers: [Int], progress: @escaping (Int, Int) -> Void) throws -> [[UInt8]] {
        var out: [[UInt8]] = []
        progress(0, layers.count)
        for (n, l) in layers.enumerated() {
            var got: [UInt8]?
            for attempt in 1...3 where got == nil {
                msleep(20)
                try send(WiredPacket.readRequest(.readMatrix, sub: UInt8(l), length: WiredPacket.chunk))
                msleep(20)
                let rsp: [UInt8]
                do { rsp = try ch.getFeature(reportID: WiredPacket.reportID, length: WiredPacket.size) } catch { throw A66Error("\(error)") }
                got = WiredPacket.matrixReply(rsp, layer: UInt8(l))
                if got == nil {
                    log(L("  读第 \(l) 层第 \(attempt) 次：回包不是键位表（\(hex(rsp.prefix(8)))），重读",
                          "  reading layer \(l), attempt \(attempt): reply is not a key table (\(hex(rsp.prefix(8)))), retrying"))
                }
            }
            guard let m = got else {
                throw A66Error(L("读第 \(l) 层失败：键盘的回包不是键位表。", "Reading layer \(l) failed: the reply is not a key table."))
            }
            out.append(m)
            progress(n + 1, layers.count)
        }
        return out
    }
}

// MARK: - 蓝牙 / 2.4G：输出/输入报告 0x13，20 字节

final class WirelessLink: A66Link {
    let ch: ReportChannel
    let connection: Connection
    let log: (String) -> Void

    init(_ ch: ReportChannel, connection: Connection, log: @escaping (String) -> Void) {
        self.ch = ch; self.connection = connection; self.log = log
    }

    func close() { ch.close() }

    /// 发读请求、收齐回包。键盘空闲后头几个请求常收不到应答（要先唤醒），所以每 0.5 秒重发一次，最多约 30 秒。
    /// 原驱动是每秒重发；缩短间隔只是更早发现键盘醒了，重发的是只读命令。
    /// 唤醒用时实测：5.0 蓝牙（FA07）0–8 秒，3.0 经典蓝牙（FA08）7–15 秒（原先 20 秒上限余量太小）。
    func readPassword(cancel: CancelFlag?) throws -> [UInt8] {
        let cmd = WirelessPacket.Command.readPassword
        let req = WirelessPacket.readRequest(cmd)
        let start = Date()
        var attempt = 0
        while Date().timeIntervalSince(start) < 30 {
            if cancel?.isCancelled == true { throw A66Error(L("已取消，没有写入任何东西。", "Cancelled; nothing was written.")) }
            attempt += 1
            ch.drain()
            do { try ch.send(req) } catch { throw A66Error("\(error)") }
            if let data = collect(cmd, firstTimeout: 0.5) {
                guard data.count >= 6 else { throw A66Error(L("回包太短：", "Reply too short: ") + hex(data)) }
                if attempt > 1 {
                    log(String(format: L("  键盘已应答（唤醒用了 %.1f 秒）", "  keyboard answered (woke up in %.1f s)"),
                               Date().timeIntervalSince(start)))
                }
                return Array(data.prefix(6))
            }
            if attempt == 1 {
                log(L("  正在唤醒键盘…（空闲后头几个请求常收不到应答）", "  waking the keyboard… (the first requests after idle often go unanswered)"))
            }
        }
        throw A66Error(L("键盘一直没有应答。确认键盘已开机、处于这个连接模式；蓝牙下检查 Karabiner 是否接管了键盘。",
                         "The keyboard never answered. Make sure it is on and in this mode; over Bluetooth check whether Karabiner grabbed it."))
    }

    /// 收一次读命令的回包；第一包等 firstTimeout，后续包各等 1 秒。超时、校验错、序号不连续、
    /// 或回显的子命令（层号）不是 sub 时返回 nil，由调用方重发。
    private func collect(_ cmd: WirelessPacket.Command, firstTimeout: TimeInterval, sub: UInt8? = nil) -> [UInt8]? {
        var data: [UInt8] = [], others = 0, timeout = firstTimeout, expected = 0
        while true {
            guard let r = ch.next(timeout: timeout) else { return nil }
            guard let part = WirelessPacket.parseReadPart(r), part.cmd == cmd.rawValue else {
                others += 1
                if others > 20 { return nil }
                continue
            }
            if part.crcError || part.index != expected { return nil }
            if let sub, part.sub != sub { return nil }
            data += part.data
            expected += 1
            if part.index + 1 >= part.total { return data }
            timeout = 1.0
        }
    }

    /// 每层发读请求 0x41，收齐回包（36 包 504 字节）。超时或不完整就同层重发，最多 3 次
    /// （2.4G 实测同一层偶尔第一次请求没有应答，重发即可）
    func readLayers(_ layers: [Int], progress: @escaping (Int, Int) -> Void) throws -> [[UInt8]] {
        let cmd = WirelessPacket.Command.readMatrix
        var out: [[UInt8]] = []
        progress(0, layers.count)
        for (n, l) in layers.enumerated() {
            var got: [UInt8]?
            for attempt in 1...3 where got == nil {
                ch.drain()
                do { try ch.send(WirelessPacket.readRequest(cmd, sub: UInt8(l))) } catch { throw A66Error("\(error)") }
                if let d = collect(cmd, firstTimeout: 1.5, sub: UInt8(l)), d.count >= Keymap.minimumReadBytes {
                    got = Array(d.prefix(Keymap.matrixBytes))
                } else {
                    log(L("  读第 \(l) 层第 \(attempt) 次没收齐，重发", "  reading layer \(l), attempt \(attempt) incomplete, resending"))
                }
            }
            guard let m = got else {
                throw A66Error(L("读第 \(l) 层失败：重发 3 次都没收齐键盘的回包。确认键盘醒着、处于这个连接模式。",
                                 "Reading layer \(l) failed: no complete reply after 3 tries. Make sure the keyboard is awake and in this mode."))
            }
            out.append(m)
            progress(n + 1, layers.count)
        }
        return out
    }

    /// 先等 200ms；逐包发送，每包前等 15ms 并等应答，超时/校验错同包重发最多 5 次；层间 30ms，结束后 50ms
    func writeLayers(_ layers: [(Int, [UInt8])], progress: @escaping (Int, Int) -> Void) throws {
        let cmd = WirelessPacket.Command.setMatrix
        let all = layers.map { (l, m) in (l, WirelessPacket.writePackets(cmd, sub: UInt8(l), data: m)) }
        let total = all.reduce(0) { $0 + $1.1.count }
        var done = 0
        progress(0, total)
        msleep(200)
        for (l, pkts) in all {
            for (i, p) in pkts.enumerated() {
                var ok = false
                for attempt in 1...5 {
                    msleep(15)
                    ch.drain()
                    do { try ch.send(p) } catch {
                        throw A66Error(L("第 \(l) 层第 \(i) 包发送失败：\(error)。这一层可能只写了一半，重新写一次即可。",
                                         "Sending layer \(l) packet \(i) failed: \(error). The layer may be half-written; just write again."))
                    }
                    var outcome = L("超时", "timeout")
                    var seen = 0
                    while seen < 20, let r = ch.next(timeout: 1.0) {
                        seen += 1
                        switch WirelessPacket.classifyAck(r, cmd: cmd) {
                        case .ok: ok = true
                        case .crcError: outcome = L("校验错", "checksum error")
                        case .deviceError:
                            throw A66Error(L("第 \(l) 层第 \(i) 包：键盘回报错误 \(hex(r))，已中止。",
                                             "Layer \(l) packet \(i): keyboard reported an error \(hex(r)); aborted."))
                        case .other: continue
                        }
                        break
                    }
                    if ok { break }
                    log(L("  第 \(l) 层第 \(i) 包第 \(attempt) 次：\(outcome)，重发",
                          "  layer \(l) packet \(i) attempt \(attempt): \(outcome), resending"))
                }
                guard ok else {
                    throw A66Error(L("第 \(l) 层第 \(i) 包重发 5 次仍失败，已中止。这一层可能只写了一半，重新写一次即可。",
                                     "Layer \(l) packet \(i) failed 5 times; aborted. The layer may be half-written; just write again."))
                }
                done += 1
                progress(done, total)
            }
            log(L("  第 \(l) 层已写入（\(pkts.count) 包，均已应答）", "  layer \(l) written (\(pkts.count) packets, all acknowledged)"))
            msleep(30)
        }
        msleep(50)
    }
}
