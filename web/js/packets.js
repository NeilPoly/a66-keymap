// 配置通道的报文格式，与 Sources/A66Core/Packet.swift、WirelessPacket.swift 一一对应。
// 命令清单里只放逆向/抓包中出现过、且本工具会用到的命令，别处不要拼裸命令字；
// 打包函数会拒绝清单以外的命令。

function check(commands, cmd) {
  if (!Object.values(commands).includes(cmd)) throw new Error(`unregistered command 0x${cmd.toString(16)}`);
}

/**
 * 有线配置通道报文（HID Feature 报告 ID 6，固定 520 字节）：
 *   [0] 报告 ID（Fw=24 时 0x06）  [1] 命令  [2] 子命令/层号  [3] 0
 *   [4] 总包数 = ceil(长度/512)  [5] 包序号  [6..7] 本包长度（小端）  [8..519] 数据
 * 读 = 先 SetFeature 发包头（数据区全 0），再 GetFeature 取回，数据从偏移 8 起。
 */
export const Wired = Object.freeze({
  reportId: 0x06,
  size: 520,
  chunk: 512,
  Command: Object.freeze({
    readPassword: 0x82, // 子命令 1，长度 6
    setMatrix: 0x03, // 子命令 = 层号 0–3，长度 512
    // 读键位表：子命令 = 层号，长度 512。原厂驱动不用；按"读 = 写 | 0x80"的规律，2026-11-03 实测可用，
    // 回包 = 包头原样回显（06 83 层 00 01 00 00 02）+ 512 字节键位表（末尾 00 00 5A A5）
    readMatrix: 0x83,
  }),

  header(cmd, sub, total, index, length) {
    return [Wired.reportId, cmd, sub, 0, total, index, length & 0xff, length >> 8];
  },

  /** @returns {Uint8Array[]} */
  packets(cmd, sub, data) {
    check(Wired.Command, cmd);
    if (!data.length) throw new Error('empty data');
    const total = Math.ceil(data.length / Wired.chunk);
    const out = [];
    for (let i = 0; i < total; i++) {
      const part = data.slice(i * Wired.chunk, Math.min(data.length, (i + 1) * Wired.chunk));
      const p = new Uint8Array(Wired.size);
      p.set(Wired.header(cmd, sub, total, i, part.length));
      p.set(part, 8);
      out.push(p);
    }
    return out;
  },

  /** 读键位表的回包 → 512 字节键位表。包头必须回显 0x83 和层号、末尾必须是 00 00 5A A5，否则返回 null。 */
  matrixReply(rsp, layer) {
    if (rsp.length < Wired.size || rsp[0] !== Wired.reportId || rsp[1] !== Wired.Command.readMatrix || rsp[2] !== layer) return null;
    const m = rsp.slice(8, Wired.size);
    return m[508] === 0x00 && m[509] === 0x00 && m[510] === 0x5a && m[511] === 0xa5 ? Uint8Array.from(m) : null;
  },

  /** 读请求：数据区全 0，只带包头 */
  readRequest(cmd, sub, length) {
    check(Wired.Command, cmd);
    if (!(length > 0 && length <= Wired.chunk)) throw new Error('bad length');
    const p = new Uint8Array(Wired.size);
    p.set(Wired.header(cmd, sub, 1, 0, length));
    return p;
  },
});

/**
 * 无线（蓝牙 / 2.4G）配置通道报文：HID 输出/输入报告 ID 0x13，固定 20 字节：
 *   [0] 0x13  [1] 命令  [2] 总包数  [3] 包序号  [4] 高 4 位=子命令(层号) 低 4 位=本包长度(≤14)
 *   [5..18] 数据  [19] 校验 = 字节 0..18 之和的低 8 位
 * 无线命令编号与有线不通用。
 */
export const Wireless = Object.freeze({
  reportId: 0x13,
  size: 20,
  chunk: 14,
  Command: Object.freeze({
    setMatrix: 0x01, // 写键位，子命令 = 层号，512 字节分 37 包，逐包应答
    readPassword: 0x05, // 读 6 字节密码
    // 读键位表：子命令 = 层号。原厂驱动不用；无线"读 = 写 + 0x40"（驱动读灯效用 0x44、写灯效 0x04），
    // 2026-11-03 经 2.4G 实测可用：回 36 包共 504 字节（少了键位表末尾的空项和 5A A5 标记，A66 的键都在前 384 字节）
    readMatrix: 0x41,
  }),

  /** 读键位表回包的字节数（36 包 × 14） */
  matrixReadBytes: 504,

  seal(b) {
    let s = 0;
    for (let i = 0; i < 19; i++) s = (s + b[i]) & 0xff;
    b[19] = s;
    return b;
  },

  /** 读请求：13 命令 01 00 (子命令<<4) … 校验 */
  readRequest(cmd, sub = 0) {
    check(Wireless.Command, cmd);
    if (!(sub >= 0 && sub < 16)) throw new Error('bad sub');
    const b = new Uint8Array(Wireless.size);
    b[0] = Wireless.reportId; b[1] = cmd; b[2] = 1; b[4] = sub << 4;
    return Wireless.seal(b);
  },

  /** 写数据分包 @returns {Uint8Array[]} */
  writePackets(cmd, sub, data) {
    check(Wireless.Command, cmd);
    if (!data.length || !(sub >= 0 && sub < 16)) throw new Error('bad args');
    const total = Math.ceil(data.length / Wireless.chunk);
    if (total >= 128) throw new Error('too long');
    const out = [];
    for (let i = 0; i < total; i++) {
      const part = data.slice(i * Wireless.chunk, Math.min(data.length, (i + 1) * Wireless.chunk));
      const b = new Uint8Array(Wireless.size);
      b[0] = Wireless.reportId; b[1] = cmd; b[2] = total; b[3] = i;
      b[4] = (sub << 4) | part.length;
      b.set(part, 5);
      out.push(Wireless.seal(b));
    }
    return out;
  },

  /** 写命令的应答判定：'ok' | 'crcError' | 'deviceError' | 'other' */
  classifyAck(r, cmd) {
    if (r.length < 3) return 'other';
    if (r[0] === 0xff) return 'deviceError';
    if (r[2] & 0x80) return 'crcError';
    if (r[1] === cmd) return 'ok';
    return 'other';
  },

  /** 读命令的应答包：[1]&0x7F=命令（最高位=校验错）、[2]&0x7F=总包数、[3]=序号、[4] 高 4 位=子命令（读键位时回显层号）、低 4 位=长度 */
  parseReadPart(r) {
    // 校验和不对的包丢掉（回包的校验规则与发送相同，2.4G / 蓝牙实测成立）
    let s = 0;
    for (let i = 0; i < 19; i++) s = (s + r[i]) & 0xff;
    if (r.length < Wireless.size || r[0] !== Wireless.reportId || s !== r[19]) return null;
    const n = Math.min(r[4] & 0x0f, Wireless.chunk);
    return {
      cmd: r[1] & 0x7f, crcError: (r[1] & 0x80) !== 0, total: r[2] & 0x7f,
      index: r[3], sub: r[4] >> 4, data: Array.from(r.slice(5, 5 + n)),
    };
  },
});
