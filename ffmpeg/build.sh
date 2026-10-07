#!/usr/bin/env bash
#
# ForkPlus-Plugins-Third_Party · ffmpeg 交付件构建
#
# 按 manifest.json 锁定的发行 tag 浅克隆 FFmpeg 源码，用固定 configure 自建共享库
# （只解码 / 无 GPL / 无外部编解码库），把各平台实际命名好的运行期库 + 许可全文摊平
# 到 staging，再交给 scripts/pack.py 打成 ffmpeg-<rid>.zip。
#
# 用法：build.sh <rid> <输出目录>          例：build.sh linux-x64 dist
#
# 三平台通用（Linux / macOS / Windows 的 MSYS2 MINGW64 都是 bash）。
# 依赖：git、python3（或 python）、make、目标平台 C 工具链；x64 另需 nasm。
#
# 摊平后的命名与 FFmpeg.AutoGen 运行期解析规则逐字对应：
#   Linux  → lib<name>.so.<major>（SONAME；归档里是软链，这里落成实体文件）
#   Windows→ <name>-<major>.dll
#   macOS  → lib<name>.<major>.dylib
set -euo pipefail

RID="${1:?用法: build.sh <rid> <输出目录>}"
OUT="$(mkdir -p "${2:?缺少输出目录}" && cd "$2" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/manifest.json"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
py() { if command -v python3 >/dev/null 2>&1; then python3 "$@"; else python "$@"; fi; }

cpu_count() {
	if command -v nproc >/dev/null 2>&1; then nproc
	elif command -v getconf >/dev/null 2>&1; then getconf _NPROCESSORS_ONLN
	elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
	else echo 2; fi
}

[ -f "$MANIFEST" ] || die "缺少清单：$MANIFEST"

# version / 源 / 运行期库名 / 许可，全部以 manifest.json 为唯一来源
read -r VERSION REF URL LIBS LICENSE < <(py - "$MANIFEST" "$RID" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], encoding="utf-8"))
rid = sys.argv[2]
if rid not in data.get("rids", []):
    sys.exit("manifest 未登记 RID " + rid)
print("\t".join([
    data["version"],
    data["sourceRef"],
    data["sourceUrl"],
    ",".join(data["runtimeLibraries"]),
    data["license"],
]))
PY
) || die "无法从 manifest.json 解析 $RID"

cc_bin="${CC:-}"
if [ -z "$cc_bin" ]; then
	for candidate in cc gcc clang; do
		if command -v "$candidate" >/dev/null 2>&1; then cc_bin="$candidate"; break; fi
	done
fi
[ -n "$cc_bin" ] || die "找不到 C 编译器（cc / gcc / clang）"

JOBS="$(cpu_count)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"
PREFIX="$WORK/prefix"
STAGE="$WORK/stage"
mkdir -p "$STAGE"

# 变量一律加花括号：macOS 的 bash 3.2 在非 UTF-8 locale 下会把紧跟 $VAR 的多字节字符
# 的首字节并进变量名，`$RID（` 会被当成变量 RID<乱码>，直接 unbound variable 退出。
log "ffmpeg ${VERSION} · ${RID}（自建，源 $URL@${REF}，${JOBS} 并发）"
git clone --depth 1 --branch "$REF" "$URL" "$SRC" >/dev/null 2>&1 || die "浅克隆失败：$URL@$REF"
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
echo "  commit: $COMMIT"

# 同一套 configure 走四个平台：只解码、无 GPL、不链接任何外部编解码库。
# 运行期库只留 5 个（avformat / avcodec / avutil / swscale / swresample），
# avdevice / avfilter / postproc 一概不构建——插件用不到（design §12）。
CONFIGURE=(
	--prefix="$PREFIX"
	--enable-shared --disable-static
	--disable-programs --disable-doc
	--disable-avdevice --disable-avfilter
	--disable-network --disable-hwaccels
	--disable-encoders --disable-muxers
	--disable-gpl --disable-nonfree --disable-version3
	--disable-autodetect --disable-debug
)
case "$RID" in
win-x64 | linux-x64) CONFIGURE+=(--enable-x86asm) ;;
osx-arm64)
	# macOS 的 dylib 默认把 install_name 写成本次构建前缀下的绝对路径（临时目录，运行期
	# 早就不存在），届时 dlopen libavformat 会因找不到 libavutil 而失败。改成 @loader_path：
	# 依赖按「引用者所在目录」解析，插件把 5 个库平铺在同一目录即可自洽。
	CONFIGURE+=(--install-name-dir='@loader_path')
	;;
esac

# zlib 是唯一允许的外部依赖（PNG 内嵌封面必需）：本机有就带，没有就降级，不让构建失败。
if printf '#include <zlib.h>\nint main(void){return 0;}\n' | "$cc_bin" -x c - -lz -o "$WORK/zlibprobe" 2>/dev/null; then
	CONFIGURE+=(--enable-zlib)
	echo "  zlib: 已启用（PNG 内嵌封面可解码）"
else
	echo "  zlib: 未检出，本次不带 --enable-zlib（PNG 内嵌封面不可解码）"
fi

log "configure"
(cd "$SRC" && ./configure "${CONFIGURE[@]}")

log "make -j$JOBS && make install"
if ! (cd "$SRC" && make -j"$JOBS" && make install) >"$WORK/make.log" 2>&1; then
	tail -n 60 "$WORK/make.log" >&2
	die "编译失败（完整日志见上）"
fi

log "摊平运行期库 → $STAGE"
libs_csv=""
stage_lib() {
	cp -L "$1" "$STAGE/$2" || die "拷贝失败：$1"
	libs_csv="${libs_csv:+$libs_csv,}$2"
}
IFS=',' read -r -a names <<<"$LIBS"

case "$RID" in
win-x64)
	for n in "${names[@]}"; do
		src="$(ls "$PREFIX/bin/$n"-[0-9]*.dll 2>/dev/null | head -n1)"
		[ -n "$src" ] || die "缺 $n-<major>.dll（$PREFIX/bin）"
		stage_lib "$src" "$(basename "$src")"
	done
	# 非系统 DLL（当前只有 zlib1.dll）必须随包分发：只认 MINGW64 前缀里的运行期 DLL，
	# 系统 DLL 在 System32，不会被误打包。
	for dll in "$STAGE"/*.dll; do
		while read -r dep; do
			[ -n "$dep" ] || continue
			[ -e "/mingw64/bin/$dep" ] || continue
			cp -L "/mingw64/bin/$dep" "$STAGE/$dep" || die "拷贝运行期依赖失败：$dep"
			libs_csv="$libs_csv,$dep"
			echo "  bundled dep: $dep"
		done < <(objdump -p "$dll" | awk '/DLL Name:/ {print $3}' | sort -u)
	done
	;;
linux-*)
	for n in "${names[@]}"; do
		src=""
		for f in "$PREFIX"/lib/lib"$n".so.[0-9]*; do
			[ -e "$f" ] || continue
			# 只要 SONAME（libx.so.<major>），跳过 libx.so.<major>.<minor>.<patch>
			case "$(basename "$f")" in *.[0-9]*.[0-9]*) continue ;; esac
			src="$f"
			break
		done
		[ -n "$src" ] || die "缺 lib$n.so.<major>（$PREFIX/lib）"
		stage_lib "$src" "$(basename "$src")"
	done
	;;
osx-arm64)
	for n in "${names[@]}"; do
		src="$(ls "$PREFIX/lib/lib$n".[0-9]*.dylib 2>/dev/null | head -n1)"
		[ -n "$src" ] || die "缺 lib$n.<major>.dylib（$PREFIX/lib）"
		stage_lib "$src" "$(basename "$src")"
	done
	;;
*)
	die "未支持的 RID：$RID"
	;;
esac

log "stage 许可全文"
cp "$SRC/LICENSE.md" "$STAGE/LICENSE.md" || die "缺 LICENSE.md"
cp "$SRC/COPYING.LGPLv2.1" "$STAGE/COPYING.LGPLv2.1" || die "缺 COPYING.LGPLv2.1"

log "打包"
py "$ROOT/scripts/pack.py" "$STAGE" "$OUT" \
	--component ffmpeg \
	--version "$VERSION" \
	--source-url "$URL" \
	--source-ref "$REF" \
	--source-commit "$COMMIT" \
	--rid "$RID" \
	--license "$LICENSE" \
	--libraries "$libs_csv"
