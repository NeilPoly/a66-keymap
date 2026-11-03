import Foundation


/// 有线配置通道报文（HID Feature 报告 ID 6，固定 520 字节），格式见 CDevG5KB::AccessData @0x4861d0：
///   [0] 报告 ID（Fw=24 时 0x06）  [1] 命令  [2] 子命令/层号  [3] 0
///   [4] 总包数 = ceil(长度/512)  [5] 包序号  [6..7] 本包长度（小端）  [8..519] 数据
/// 读 = 先 SetFeature 发包头（数据区全 0），再 GetFeature 取回，数据从偏移 8 起。
public enum WiredPacket {
    public static let reportID: UInt8 = 0x06
    public static let size = 520
    public static let chunk = 512

    /// 命令清单里只放逆向/抓包中出现过的命令，别处不要拼裸命令字。
    public enum Command: UInt8 {
        case readPassword = 0x82   // 子命令 1，长度 6
        case setMatrix = 0x03      // 子命令 = 层号 0–3，长度 512
        /// 读键位表：子命令 = 层号，长度 512。原厂驱动不用；按"读 = 写 | 0x80"的规律，2026-11-03 实测可用，
        /// 回包 = 包头原样回显（06 83 层 00 01 00 00 02）+ 512 字节键位表（末尾 00 00 5A A5）
        case readMatrix = 0x83
    }

    public static func packets(_ cmd: Command, sub: UInt8, data: [UInt8]) -> [[UInt8]] {
        precondition(!data.isEmpty)
        let total = (data.count + chunk - 1) / chunk
        return (0..<total).map { i in
            let part = Array(data[(i * chunk)..<min(data.count, (i + 1) * chunk)])
            return header(cmd, sub: sub, total: total, index: i, length: part.count) + part
                + Array(repeating: 0, count: chunk - part.count)
        }
    }

    /// 读请求：数据区全 0，只带包头
    public static func readRequest(_ cmd: Command, sub: UInt8, length: Int) -> [UInt8] {
        precondition(length > 0 && length <= chunk)
        return header(cmd, sub: sub, total: 1, index: 0, length: length) + Array(repeating: 0, count: chunk)
    }

    /// 读键位表的回包 → 512 字节键位表。包头必须回显 0x83 和层号、末尾必须是 00 00 5A A5，否则返回 nil。
    public static func matrixReply(_ rsp: [UInt8], layer: UInt8) -> [UInt8]? {
        guard rsp.count >= size, rsp[0] == reportID, rsp[1] == Command.readMatrix.rawValue, rsp[2] == layer else { return nil }
        let m = Array(rsp[8..<size])
        return m.suffix(4) == [0x00, 0x00, 0x5A, 0xA5] ? m : nil
    }

    static func header(_ cmd: Command, sub: UInt8, total: Int, index: Int, length: Int) -> [UInt8] {
        [reportID, cmd.rawValue, sub, 0, UInt8(total), UInt8(index), UInt8(length & 0xFF), UInt8(length >> 8)]
    }
}

public func hex(_ b: some Collection<UInt8>, sep: String = " ") -> String {
    b.map { String(format: "%02X", $0) }.joined(separator: sep)
}
