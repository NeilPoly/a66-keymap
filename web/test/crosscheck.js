// 与 Swift 版逐字节对照：用 a66 build 生成的有线报文（layerN.bin）和网页版算出来的比较。
// 用法：node test/crosscheck.js <keymap.json 或 profile.dct> <a66 build 的输出目录>
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { Keymap } from '../js/keymap.js';
import { Wired } from '../js/packets.js';
import { keymapFromWindowsProfile } from '../js/windows-import.js';

const [input, refDir] = process.argv.slice(2);
if (!input || !refDir) {
  console.error('usage: node test/crosscheck.js <keymap.json|profile.dct> <ref-dir>');
  process.exit(2);
}
const k = input.toLowerCase().endsWith('.dct')
  ? keymapFromWindowsProfile(new Uint8Array(readFileSync(input)))
  : Keymap.fromJSON(readFileSync(input, 'utf8'));
let bad = 0;
for (let l = 0; l < 3; l++) {
  const mine = Wired.packets(Wired.Command.setMatrix, l, k.matrix(l))[0];
  const ref = new Uint8Array(readFileSync(join(refDir, `layer${l}.bin`)));
  const same = mine.length === ref.length && mine.every((v, i) => v === ref[i]);
  console.log(`layer ${l}: ${same ? 'identical' : 'DIFFERENT'} (${mine.length} / ${ref.length} bytes)`);
  if (!same) bad++;
}
process.exit(bad ? 1 : 0);
