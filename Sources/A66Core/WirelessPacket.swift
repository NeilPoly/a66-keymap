import Foundation

/// 无线（蓝牙 / 2.4G）配置通道报文：HID 输出/输入报告 ID 0x13，固定 20 字节。
/// 格式见 CDev3632::AccessData @0x482c20 与 SendCMD_3632 @0x483530：
///   [0] 0x13  [1] 命令  [2] 总包数  [3] 包序号  [4] 高 4 位=子命令(层号) 低 4 位=本包长度(≤14)
///   [5..18] 数据  [19] 校验 = 字节 0..18 之和的低 8 位（FUN_00483240）
/// 无线命令编号与有线不通用。
public enum WirelessPacket {
    public static let reportID: UInt8 = 0x13
    public static let size = 20
    public static let chunk = 14

    /// 只登记逆向中出现、且本工具会用到的命令
    public enum Command: UInt8 {
        case setMatrix = 0x01      // 写键位，子命令 = 层号，512 字节分 37 包，逐包应答
        case readPassword = 0x05   // 读 6 字节密码（Watcher_Thread_3632 的 GetPSD）
        /// 读键位表：子命令 = 层号。原厂驱动不用；无线"读 = 写 + 0x40"（驱动读灯效用 0x44、写灯效 0x04，
        /// CDev3632::GetLED @0x482ed0），2026-11-03 经 2.4G 实测可用：回 36 包共 504 字节
        /// （少了键位表末尾的空项和 5A A5 标记，A66 的键都在前 384 字节）
        case readMatrix = 0x41
    }

    /// 读键位表回包的字节数（36 包 × 14）
    public static let matrixReadBytes = 504

    static func checksum(_ b: [UInt8]) -> UInt8 {
        b[0..<19].reduce(0) { $0 &+ $1 }
    }

    static func seal(_ b: inout [UInt8]) { b[19] = checksum(b) }

    /// 读请求：`13 命令 01 00 (子命令<<4) … 校验`
    public static func readRequest(_ cmd: Command, sub: UInt8 = 0) -> [UInt8] {
        precondition(sub < 16)
        var b = [UInt8](repeating: 0, count: size)
        b[0] = reportID; b[1] = cmd.rawValue; b[2] = 1; b[4] = sub << 4
        seal(&b)
        return b
    }

    /// 写数据分包
    public static func writePackets(_ cmd: Command, sub: UInt8, data: [UInt8]) -> [[UInt8]] {
        precondition(!data.isEmpty && sub < 16)
        let total = (data.count + chunk - 1) / chunk
        precondition(total < 128)
        return (0..<total).map { i in
            let part = data[(i * chunk)..<min(data.count, (i + 1) * chunk)]
            var b = [UInt8](repeating: 0, count: size)
            b[0] = reportID; b[1] = cmd.rawValue; b[2] = UInt8(total); b[3] = UInt8(i)
            b[4] = sub << 4 | UInt8(part.count)
            for (j, v) in part.enumerated() { b[5 + j] = v }
            seal(&b)
            return b
        }
    }

    /// 写命令的应答判定（FUN_00482840）
    public enum Ack { case ok, crcError, deviceError, other }

    public static func classifyAck(_ r: [UInt8], cmd: Command) -> Ack {
        guard r.count >= 3 else { return .other }
        if r[0] == 0xFF { return .deviceError }
        if r[2] & 0x80 != 0 { return .crcError }
        if r[1] == cmd.rawValue { return .ok }
        return .other
    }

    /// 读命令的应答包（SendCMD_3632）：[1]&0x7F=命令（最高位=校验错）、[2]&0x7F=总包数、[3]=序号、
    /// [4] 高 4 位=子命令（读键位时回显层号）、低 4 位=长度
    public struct ReadPart {
        public let cmd: UInt8, crcError: Bool, total: Int, index: Int, sub: UInt8, data: [UInt8]
    }

    /// 校验和不对的包返回 nil（回包的校验规则与发送相同，2.4G / 蓝牙实测成立）
    public static func parseReadPart(_ r: [UInt8]) -> ReadPart? {
        guard r.count >= size, r[0] == reportID, checksum(r) == r[19] else { return nil }
        let n = min(Int(r[4] & 0x0F), chunk)
        return ReadPart(cmd: r[1] & 0x7F, crcError: r[1] & 0x80 != 0, total: Int(r[2] & 0x7F),
                        index: Int(r[3]), sub: r[4] >> 4, data: Array(r[5..<5 + n]))
    }
}
