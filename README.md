# ForkPlus-Plugins-Third_Party

[![build passing](https://github.com/hebin123456/ForkPlus-Plugins-Third_Party/actions/workflows/build.yml/badge.svg?branch=master)](https://github.com/hebin123456/ForkPlus-Plugins-Third_Party/actions/workflows/build.yml)
[![release](https://img.shields.io/github/v/release/hebin123456/ForkPlus-Plugins-Third_Party?label=release&color=blue)](https://github.com/hebin123456/ForkPlus-Plugins-Third_Party/releases)
[![license: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

ForkPlus 插件的**三方件源码仓**：把插件依赖的原生库（源码）统一收到这里，自建编译，
出四平台交付件，由插件仓（[ForkPlus-Plugins](https://github.com/hebin123456/ForkPlus-Plugins)）
直接消费产物。

为什么自建：上游现成的二进制供给不齐（如 FFmpeg 的 macOS LGPL 共享构建长期缺位），
且 configure 开关不可控。自建后四个平台用**同一套 configure**、同一份源码，能力一致、
许可干净（只解码、无 GPL）。

## 目录

```
<component>/manifest.json     组件清单：版本 / 来源 / 许可 / 构建约束 / RID 列表
<component>/build.sh          按清单浅克隆源码 → 固定 configure 自建 → 摊平到 staging
scripts/matrix.py             「组件 × RID」→ GitHub Actions matrix
scripts/index.py              各平台打包记录 → Release 的 index.json + 说明
scripts/pack.py               摊平目录 → <component>-<rid>.zip（+ 同名校验 JSON）
.github/workflows/build.yml   tag → 四平台构建 → Release
```

组件是**平级目录**，一个三方件一个目录，互不干扰。当前：

| 组件 | 版本 | 许可 | 消费方 |
| --- | --- | --- | --- |
| `ffmpeg` | 9.0.2 | LGPL-2.1-or-later | `ForkPlus.Plugins.Audio` / `ForkPlus.Plugins.Video` |
| `miniaudio` | 0.11.25 | Unlicense OR MIT-0 | `ForkPlus.Plugins.Audio` / `ForkPlus.Plugins.Video` |

`miniaudio` 只负责**音频输出**（解码仍由 `ffmpeg` 负责），随目录另附一层自写的 C ABI
垫片（`fpp_audio.c/.h`）：把 `miniaudio.h` 以 `MINIAUDIO_IMPLEMENTATION` 编进同一 TU，
对外只导出 `fpp_audio_*` 的**不透明句柄**接口，避免 miniaudio 的 ABI 波动传到 .NET。
交付件名不是通用的 `<name>-<major>.dll`，而是按插件仓 `MiniAudioNative.LibraryFileName()`
逐字命名：Linux `libfpp_audio.so.0` / Windows `fpp_audio.dll` / macOS `libfpp_audio.0.dylib`。

## 出包

推版本 tag 即自动出包并建 Release：

```
git tag 0.0.1 && git push origin 0.0.1
```

四平台（`win-x64` / `linux-x64` / `linux-arm64` / `osx-arm64`）各自构建，产物：

- `<component>-<rid>.zip` —— 稳定名，内容**平铺**：
  - 运行期库（Linux 按 SONAME `lib<name>.so.<major>`；Windows `<name>-<major>.dll`；macOS `lib<name>.<major>.dylib`）
  - `LICENSE.md` + `COPYING.LGPLv2.1`（许可全文，随件分发）
  - `component.json`（本包逐文件的 sha256，用于溯源）
- `index.json` —— 全部交付件的 sha256 / 大小 / 运行期库名，**插件仓的消费接口**

`index.json` 的字段是跨仓契约，改格式等于改接口。

`workflow_dispatch` 手动触发只构建 + 上传 Artifacts，不发 Release。

## 新增一个三方件

1. 建 `<component>/`，写 `manifest.json`（`component` / `version` / `sourceUrl` /
   `sourceRef` / `license` / `runtimeLibraries` / `rids` 必填，`rids` 用上表四个 RID）。
2. 写 `build.sh <rid> <输出目录>`：浅克隆源码 → 编译 → 把交付文件摊平到 staging →
   调 `scripts/pack.py` 打包。可照抄 `ffmpeg/build.sh`。
3. 若新平台 / 新工具链，改 `scripts/matrix.py` 的 `RUNNERS`；否则 CI **无需改动**。
4. 本地跑一遍再推：

   ```
   bash <component>/build.sh linux-x64 dist
   ```

## 插件仓怎么消费

`releases/latest/download/index.json` → 找到本 RID 的 `asset` 与 `sha256` →
下载 `releases/latest/download/<asset>` → 校验 sha256 → 解出运行期库到插件的
`third_party/<component>/<rid>/`。全程**不锁版本**，新 tag 一发，插件仓下次构建即自动跟上。
