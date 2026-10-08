#!/usr/bin/env bash
#
# ForkPlus-Plugins-Third_Party · miniaudio 交付件构建
#
# 按 manifest.json 锁定的上游 tag 浅克隆 miniaudio 源码，把同目录的 C ABI 垫片
# fpp_audio.c/.h 与上游的 miniaudio.h 一起编成**共享库**（只导出 fpp_audio_* 符号），
# 摊平到 staging，再交给 scripts/pack.py 打成 miniaudio-<rid>.zip。
#
# 用法：build.sh <rid> <输出目录>          例：build.sh linux-x64 dist
#
# 三平台通用（Linux / macOS / Windows 的 MSYS2 MINGW64 都是 bash）。
# 依赖：git、python3（或 python）、目标平台 C 工具链。
#
# 命名与插件仓 MiniAudioNative.LibraryFileName() 逐字对应：
#   Linux  → libfpp_audio.so.0（SONAME）
#   Windows→ fpp_audio.dll
#   macOS  → libfpp_audio.0.dylib（install_name = @loader_path/libfpp_audio.0.dylib）
#
# miniaudio 本体对 ALSA / PulseAudio / CoreAudio / WASAPI 一律**运行期** dlopen，
# 产物不产生指向 libasound / libpulse / 各 framework 的 DT_NEEDED（构建也无需任何 -dev 包）。
set -euo pipefail

RID="${1:?用法: build.sh <rid> <输出目录>}"
OUT="$(mkdir -p "${2:?缺少输出目录}" && cd "$2" && pwd)"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MANIFEST="$HERE/manifest.json"

log() { printf '\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }
py() { if command -v python3 >/dev/null 2>&1; then python3 "$@"; else python "$@"; fi; }

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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$WORK/src"
STAGE="$WORK/stage"
mkdir -p "$STAGE"

# 变量一律加花括号：macOS 的 bash 3.2 在非 UTF-8 locale 下会把紧跟 $VAR 的多字节字符
# 的首字节并进变量名（`$RID（` 会被当成变量 RID<乱码>，直接 unbound variable 退出）。
log "miniaudio ${VERSION} · ${RID}（自建，源 $URL@${REF}）"
git clone --depth 1 --branch "$REF" "$URL" "$SRC" >/dev/null 2>&1 || die "浅克隆失败：$URL@$REF"
COMMIT="$(git -C "$SRC" rev-parse HEAD)"
echo "  commit: $COMMIT"

[ -f "$SRC/miniaudio.h" ] || die "源码里缺 miniaudio.h：$SRC"

# 编垫片：miniaudio.h 由 MINIAUDIO_IMPLEMENTATION 编进同一 TU（见 fpp_audio.c）。
# 打开重定位（-fPIC）以便作为共享库加载。
# Linux 只需 -ldl -lpthread -lm；Windows / macOS 无链接依赖（后端运行期 dlopen）。
CFLAGS_COMMON=(-O2 -fPIC -fvisibility=default)
case "$RID" in
win-x64)
	"$cc_bin" -shared "${CFLAGS_COMMON[@]}" -o "$STAGE/fpp_audio.dll" \
		"$HERE/fpp_audio.c" -I"$HERE" -I"$SRC" \
		|| die "编译失败（win-x64）"
	;;
linux-*)
	"$cc_bin" -shared "${CFLAGS_COMMON[@]}" -o "$STAGE/libfpp_audio.so.0" \
		-Wl,-soname,libfpp_audio.so.0 \
		"$HERE/fpp_audio.c" -I"$HERE" -I"$SRC" \
		-ldl -lpthread -lm \
		|| die "编译失败（${RID}）"
	;;
osx-arm64)
	# install_name 用 @loader_path：依赖者按自身所在目录解析，插件平铺即自洽
	# （与 ffmpeg 的 dylib 同一策略，见 ffmpeg/build.sh）。
	"$cc_bin" -dynamiclib "${CFLAGS_COMMON[@]}" -o "$STAGE/libfpp_audio.0.dylib" \
		-install_name @loader_path/libfpp_audio.0.dylib \
		"$HERE/fpp_audio.c" -I"$HERE" -I"$SRC" \
		-lpthread -lm \
		|| die "编译失败（osx-arm64）"
	;;
*)
	die "未支持的 RID：$RID"
	;;
esac

log "stage 许可全文"
cp "$SRC/LICENSE" "$STAGE/LICENSE.miniaudio" || die "缺上游 LICENSE"

# 实际产出的运行期库文件名（一个 RID 一个），交给 pack.py 校验并写进 index.json。
case "$RID" in
win-x64) LIBFILE="fpp_audio.dll" ;;
linux-*) LIBFILE="libfpp_audio.so.0" ;;
osx-arm64) LIBFILE="libfpp_audio.0.dylib" ;;
esac
[ -f "$STAGE/$LIBFILE" ] || die "缺运行期库：$LIBFILE"
echo "  运行期库：$LIBFILE"

log "打包"
py "$ROOT/scripts/pack.py" "$STAGE" "$OUT" \
	--component miniaudio \
	--version "$VERSION" \
	--source-url "$URL" \
	--source-ref "$REF" \
	--source-commit "$COMMIT" \
	--rid "$RID" \
	--license "$LICENSE" \
	--libraries "$LIBFILE"