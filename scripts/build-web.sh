#!/bin/bash
# 打包网页版到 dist/web：只拷要发布的文件，并给页面引用和 JS 模块之间的 import 加 ?v=版本，
# 这样更新网站后浏览器不会混用新旧缓存。不需要任何依赖。
# 用法：scripts/build-web.sh 0.1.0
set -euo pipefail

VERSION="${1:?用法：scripts/build-web.sh <版本号>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/web"
OUT="$ROOT/dist/web"

(cd "$SRC" && node --test test/core.test.js >/dev/null) || { echo "单元测试没通过，已停止" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/js"
# og.png 是分享到社交网站时显示的预览图（1200×630）
cp "$SRC/index.html" "$SRC/style.css" "$SRC/favicon.svg" "$SRC/og.png" "$OUT/"
cp "$SRC"/js/*.js "$OUT/js/"

# 页面里的 style.css / js/app.js，以及模块里的 from './x.js'
sed -i '' -e "s#href=\"style.css\"#href=\"style.css?v=$VERSION\"#" \
          -e "s#src=\"js/app.js\"#src=\"js/app.js?v=$VERSION\"#" "$OUT/index.html"
sed -i '' -E "s#(from '\./[a-z0-9-]+\.js)'#\1?v=$VERSION'#g" "$OUT"/js/*.js

# 核对：每个模块的相对 import 都带上了版本号
if grep -nE "from '\./[^']+\.js'" "$OUT"/js/*.js; then
  echo "上面这些 import 没加版本号" >&2
  exit 1
fi

echo "已生成 ${OUT}（版本 ${VERSION}）："
(cd "$OUT" && find . -type f | sort | xargs ls -l | awk '{printf "  %6d  %s\n", $5, $9}')
