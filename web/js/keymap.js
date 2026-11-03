import { L } from './l10n.js';
import { FN, NONE, RESET_KEYBOARD, bytes, fromHex, hex8 } from './keycode.js';
import { KEYS, factoryCode, keySpec } from './layout.js';

// 与 Sources/A66Core/Keymap.swift 一一对应。

export const LAYER_COUNT = 3;
/** 每层的键位表条目数（每条 4 字节），最后一条固定为校验字 00 00 5A A5 */
export const MATRIX_ENTRIES = 128;
export const MATRIX_BYTES = MATRIX_ENTRIES * 4;

/**
 * 三层键位：第 0 层 = 普通层，第 1 层 = 按住 Fn 时，第 2 层 = 原驱动的 FN2 层（一般只放 Fn 键）。
 * 第 3 层本工具从不写入。
 *
 * 键盘不能读回键位表，所以这里保存的是"要写进去 / 上次写进去"的配置。
 */
export class Keymap {
  /** @param {Map<number, number>[]} [layers] layers[层].get(K 编号) = 设备码；不在表里的键为空 */
  constructor(layers) {
    this.layers = layers ?? Array.from({ length: LAYER_COUNT }, () => new Map());
  }

  clone() {
    return new Keymap(this.layers.map((m) => new Map(m)));
  }

  /** 出厂键位：普通层 + Fn 层，FN2 层为空 */
  static factory() {
    const k = new Keymap();
    for (const spec of KEYS) {
      for (const l of [0, 1]) {
        const c = factoryCode(spec, l);
        if (c !== NONE) k.layers[l].set(spec.id, c);
      }
    }
    return k;
  }

  /** 出厂键位，但把 Fn+CapsLock 的复位挪到 Fn+Delete（见 moveResetToFnDelete）。网页默认显示出厂键位，这个只给测试用，与 Swift 版 `a66 init` 对应 */
  static recommended() {
    const k = Keymap.factory();
    k.moveResetToFnDelete();
    return k;
  }

  code(layer, key) {
    return this.layers[layer].get(key) ?? NONE;
  }

  isFactory(layer, key) {
    const spec = keySpec(key);
    return this.code(layer, key) === (spec ? factoryCode(spec, layer) : NONE);
  }

  /**
   * 改一个键。普通层的键改成 Fn 时，Fn 层和 FN2 层的同一个键也设成 Fn（原驱动的做法：
   * 按住这个键进入 Fn 层后，它在 Fn 层里也得是 Fn）；普通层的 Fn 改成别的时，这两层恢复出厂。
   */
  set(code, layer, key) {
    if (!(layer >= 0 && layer < LAYER_COUNT) || !keySpec(key)) throw new Error(`bad key L${layer} K${key}`);
    code >>>= 0;
    const old = this.code(layer, key);
    this.#put(code, layer, key);
    if (layer !== 0 || old === code) return;
    if (code === FN) {
      this.#put(FN, 1, key);
      this.#put(FN, 2, key);
    } else if (old === FN) {
      for (const l of [1, 2]) this.#put(factoryCode(keySpec(key), l), l, key);
    }
  }

  #put(code, layer, key) {
    if (code === NONE) this.layers[layer].delete(key);
    else this.layers[layer].set(key, code >>> 0);
  }

  /** 恢复一个键的出厂设置（同样遵守 Fn 联动） */
  resetToFactory(layer, key) {
    this.set(factoryCode(keySpec(key), layer), layer, key);
  }

  // MARK: - 复位键

  /**
   * 出厂 Fn+CapsLock = 复位键盘：按住约 5 秒会把键位清回出厂。CapsLock 改成 Ctrl 后，
   * 任何"Ctrl + Fn 层的键"都容易先按到 Fn 而误触。这里把复位挪到 Fn+Delete（右侧，单手很难误按），
   * Fn+CapsLock 改成与普通层的 CapsLock 位置相同的功能。
   */
  moveResetToFnDelete() {
    const caps = 33, del = 31;
    if (this.code(1, caps) === RESET_KEYBOARD) {
      const base = this.code(0, caps);
      this.#put(base === FN ? FN : base, 1, caps);
    }
    this.#put(RESET_KEYBOARD, 1, del);
  }

  /** 复位键在哪些键上 [{layer, key}] */
  get resetKeys() {
    const out = [];
    for (let l = 0; l < LAYER_COUNT; l++) {
      const ks = [...this.layers[l]].filter(([, c]) => c === RESET_KEYBOARD).map(([k]) => k).sort((a, b) => a - b);
      for (const key of ks) out.push({ layer: l, key });
    }
    return out;
  }

  /** 普通层有没有 Fn 键。没有的话进不了 Fn 层（切换连接、灯光、复位都用不了）。 */
  get hasFnKey() {
    return [...this.layers[0].values()].includes(FN);
  }

  // MARK: - 键位表

  /** 某一层的键位表（512 字节）：每个键的设备码按字节顺序放在 矩阵号×4 处，最后 4 字节为 00 00 5A A5。 */
  matrix(layer) {
    const m = new Uint8Array(MATRIX_BYTES);
    for (const [id, code] of this.layers[layer]) {
      const spec = keySpec(id);
      if (!spec) continue;
      if (!(spec.matrix >= 0 && spec.matrix < MATRIX_ENTRIES - 1)) throw new Error(`bad matrix K${id}`);
      m.set(bytes(code), spec.matrix * 4);
    }
    m.set([0x00, 0x00, 0x5a, 0xa5], MATRIX_BYTES - 4);
    return m;
  }

  // MARK: - 从键盘读回

  /** 读回的数据至少要这么长才覆盖 A66 的所有键 */
  static get minimumReadBytes() {
    return (Math.max(...KEYS.map((k) => k.matrix)) + 1) * 4;
  }

  /**
   * 用读回的各层键位表组成配置。每层至少要覆盖到 A66 用到的最大矩阵号（无线读回 504 字节、有线 512 字节）；
   * 最后一项（校验位 00 00 5A A5）不算键。unknown = 不在 A66 键位排列上却有内容的位置（读入时忽略）。
   * @param {Uint8Array[]} ms
   */
  static fromMatrices(ms) {
    if (ms.length !== LAYER_COUNT) throw new Error('need 3 layers');
    const known = new Map(KEYS.map((k) => [k.matrix, k.id]));
    const k = new Keymap();
    const unknown = [];
    ms.forEach((m, l) => {
      if (m.length < Keymap.minimumReadBytes) throw new Error('read-back too short');
      for (let i = 0; i < Math.min(m.length >> 2, MATRIX_ENTRIES - 1); i++) {
        const code = ((m[i * 4] << 24) | (m[i * 4 + 1] << 16) | (m[i * 4 + 2] << 8) | m[i * 4 + 3]) >>> 0;
        if (code === NONE) continue;
        if (known.has(i)) k.layers[l].set(known.get(i), code);
        else unknown.push({ layer: l, index: i, code });
      }
    });
    return { keymap: k, unknown };
  }

  /** 读回的一层（可能比 512 字节短）和这份配置的这一层是否一致 */
  matches(readBack, layer) {
    const m = this.matrix(layer);
    return readBack.length >= Keymap.minimumReadBytes && readBack.length <= m.length && readBack.every((v, i) => v === m[i]);
  }

  // MARK: - 比较

  /** 相对 other 改了哪些键（按层、K 编号排序）：[{layer, key, from, to}] */
  changes(other) {
    const out = [];
    for (let l = 0; l < LAYER_COUNT; l++) {
      const ids = [...new Set([...this.layers[l].keys(), ...other.layers[l].keys()])].sort((a, b) => a - b);
      for (const id of ids) {
        const a = other.code(l, id), b = this.code(l, id);
        if (a !== b) out.push({ layer: l, key: id, from: a, to: b });
      }
    }
    return out;
  }

  /** 哪些层和 other 不同 */
  changedLayers(other) {
    const out = [];
    for (let l = 0; l < LAYER_COUNT; l++) {
      const a = this.matrix(l), b = other.matrix(l);
      if (a.some((v, i) => v !== b[i])) out.push(l);
    }
    return out;
  }

  /** 把指定层换成 other 的（用来记录"写入后键盘里是什么"） */
  replacing(layers, other) {
    const k = this.clone();
    for (const l of layers) k.layers[l] = new Map(other.layers[l]);
    return k;
  }

  equals(other) {
    return this.changes(other).length === 0;
  }

  // MARK: - 文件格式
  // { "format": "a66-keymap", "version": 1,
  //   "layers": [ { "K1": "00000029", ... }, { ... }, { ... } ] }
  // 设备码是 8 位十六进制、按字节顺序书写；没列出的键为空。与 Mac app / 命令行的文件通用。

  toJSON() {
    const layers = this.layers.map((m) => {
      const o = {};
      for (const id of [...m.keys()].map((k) => `K${k}`).sort()) o[id] = hex8(m.get(Number(id.slice(1))));
      return o;
    });
    return { format: 'a66-keymap', layers, version: 1 };
  }

  toJSONString() {
    return JSON.stringify(this.toJSON(), null, 2) + '\n';
  }

  /** 解析键位文件，不认识的内容抛出带说明的 Error */
  static fromJSON(text) {
    let o;
    try { o = typeof text === 'string' ? JSON.parse(text) : text; } catch {
      throw new Error(L('不是 A66 键位文件', 'not an A66 keymap file'));
    }
    if (!o || o.format !== 'a66-keymap' || !Array.isArray(o.layers)) {
      throw new Error(L('不是 A66 键位文件', 'not an A66 keymap file'));
    }
    if (o.version !== 1) throw new Error(L(`不支持的版本 ${o.version}`, `unsupported version ${o.version}`));
    const k = new Keymap();
    o.layers.slice(0, LAYER_COUNT).forEach((dict, l) => {
      if (!dict || typeof dict !== 'object') throw new Error(L('看不懂的条目', 'invalid entry'));
      for (const [name, h] of Object.entries(dict)) {
        const m = /^K(\d+)$/.exec(name);
        const id = m ? Number(m[1]) : NaN;
        const code = fromHex(h);
        if (!keySpec(id) || code === null) {
          throw new Error(L(`看不懂的条目：${name}=${h}`, `invalid entry: ${name}=${h}`));
        }
        if (code !== NONE) k.layers[l].set(id, code);
      }
    });
    return k;
  }
}
