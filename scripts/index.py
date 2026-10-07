#!/usr/bin/env python3
"""ForkPlus-Plugins-Third_Party · Release 索引汇总

各平台构建 job 会把 pack.py 产出的 <component>-<rid>.json（含 asset / sha256 / bytes /
libraries 等）作为产物上传。这里把它们汇总成 Release 的 index.json，并生成 Release 说明。

插件仓的取件脚本按 `releases/latest/download/index.json` 拿各 RID 的 sha256 再校验下载，
因此本文件是「插件仓不锁版本、自动消费最新 tag」的关键接口——**格式变更属破坏性变更**。

用法：
  index.py <产物目录> <输出的 index.json> [--body 说明.md] [--tag 0.0.1]
"""
import argparse
import glob
import json
import os
import sys


def human_bytes(n):
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return "{:.0f} {}".format(n, unit) if unit == "B" else "{:.1f} {}".format(n, unit)
        n /= 1024.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("artifacts", help="构建产物目录（递归查找 <component>-<rid>.json）")
    ap.add_argument("index", help="输出的 index.json 路径")
    ap.add_argument("--body", help="同时写出的 Release 说明 Markdown")
    ap.add_argument("--tag", default="", help="Release tag，写进 index 与说明")
    args = ap.parse_args()

    records = []
    for path in sorted(glob.glob(os.path.join(args.artifacts, "**", "*.json"), recursive=True)):
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (ValueError, OSError) as err:
            sys.exit("读取打包记录失败：{}（{}）".format(path, err))
        # pack.py 的记录长这样；别的 json 一律忽略
        if {"component", "rid", "asset", "sha256"} <= set(data):
            records.append(data)

    if not records:
        sys.exit("没有找到任何打包记录（<component>-<rid>.json）：" + args.artifacts)

    components = {}
    for r in records:
        c = components.setdefault(r["component"], {
            "component": r["component"],
            "version": r["version"],
            "sourceUrl": r["sourceUrl"],
            "sourceRef": r["sourceRef"],
            "sourceCommit": r.get("sourceCommit"),
            "license": r["license"],
            "assets": [],
        })
        c["assets"].append({
            "rid": r["rid"],
            "asset": r["asset"],
            "sha256": r["sha256"],
            "bytes": r["bytes"],
            "libraries": r.get("libraries", []),
        })

    for c in components.values():
        c["assets"].sort(key=lambda a: a["rid"])

    index = {"tag": args.tag, "components": [components[k] for k in sorted(components)]}
    with open(args.index, "w", encoding="utf-8", newline="\n") as f:
        json.dump(index, f, ensure_ascii=False, indent=2)
        f.write("\n")

    if args.body:
        lines = []
        if args.tag:
            lines.append("三方件交付件 · `{}`".format(args.tag))
            lines.append("")
        for c in index["components"]:
            commit = (c.get("sourceCommit") or "")[:12]
            lines.append("### `{}` {} · {}".format(c["component"], c["version"], c["license"]))
            lines.append("")
            lines.append("源：{} @ `{}`{}".format(
                c["sourceUrl"], c["sourceRef"], "（`{}`）".format(commit) if commit else ""))
            lines.append("")
            lines.append("| RID | 交付件 | 大小 | sha256 |")
            lines.append("| --- | --- | --- | --- |")
            for a in c["assets"]:
                lines.append("| `{}` | `{}` | {} | `{}` |".format(
                    a["rid"], a["asset"], human_bytes(a["bytes"]), a["sha256"]))
            lines.append("")
        lines.append("取件方式：插件仓按 `releases/latest/download/index.json` 解析各 RID 的 "
                     "sha256，再下载 `releases/latest/download/<asset>` 并校验。")
        with open(args.body, "w", encoding="utf-8", newline="\n") as f:
            f.write("\n".join(lines) + "\n")

    total = sum(len(c["assets"]) for c in index["components"])
    print("components: " + ", ".join(c["component"] for c in index["components"]))
    print("assets: {}".format(total))


if __name__ == "__main__":
    main()
