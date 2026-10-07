#!/usr/bin/env python3
"""ForkPlus-Plugins-Third_Party · 构建矩阵枚举

扫描本仓根目录下所有 <component>/manifest.json，把「组件 × RID」展开成 GitHub Actions
的 matrix。新增组件只需建目录 + 写 manifest，不用改 workflow。

输出（写进 $GITHUB_OUTPUT）：
  matrix={"include":[{"component":"ffmpeg","rid":"linux-x64","os":"ubuntu-latest"}, ...]}

用法：python3 scripts/matrix.py >> "$GITHUB_OUTPUT"
"""
import json
import os
import sys

# RID → runner。与 ForkPlus 宿主的四平台一致（见插件仓 .github/workflows/build.yml）。
RUNNERS = {
    "win-x64": "windows-latest",
    "linux-x64": "ubuntu-latest",
    "linux-arm64": "ubuntu-22.04-arm",
    "osx-arm64": "macos-latest",
}


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    include = []
    unknown = []
    for entry in sorted(os.listdir(root)):
        manifest = os.path.join(root, entry, "manifest.json")
        if not os.path.isfile(manifest):
            continue
        with open(manifest, encoding="utf-8") as f:
            data = json.load(f)
        component = data.get("component") or entry
        for rid in data.get("rids", []):
            if rid not in RUNNERS:
                unknown.append("{}:{}".format(component, rid))
                continue
            include.append({"component": component, "rid": rid, "os": RUNNERS[rid]})

    if unknown:
        sys.exit("manifest 里出现未登记 runner 的 RID：" + " ".join(unknown))
    if not include:
        sys.exit("没有发现任何组件（<component>/manifest.json）")

    print("matrix=" + json.dumps({"include": include}, separators=(",", ":")))


if __name__ == "__main__":
    main()
