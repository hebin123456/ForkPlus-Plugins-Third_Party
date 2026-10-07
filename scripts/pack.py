#!/usr/bin/env python3
"""ForkPlus-Plugins-Third_Party · 交付件打包

把一个组件在某个 RID 上"摊平"好的运行期文件（+ 许可全文）打成对外的 zip，并产出
一份溯源与校验用的 JSON：既写进包内（component.json），也写在包旁供 release 汇总
成 index.json。zip 用固定时间戳与排序生成，同一输入产出同一字节序列，便于比对。

用法：
  pack.py <摊平目录> <输出目录> --component ffmpeg --version 9.0.2 \
          --source-url https://github.com/FFmpeg/FFmpeg --source-ref n9.0.2 \
          --source-commit <sha> --rid linux-x64 --license LGPL-2.1-or-later
"""
import argparse
import hashlib
import json
import os
import sys
import zipfile

FIXED_DATE = (1980, 1, 1, 0, 0, 0)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("stage")
    ap.add_argument("outdir")
    ap.add_argument("--component", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--source-url", required=True)
    ap.add_argument("--source-ref", required=True)
    ap.add_argument("--source-commit", required=True)
    ap.add_argument("--rid", required=True)
    ap.add_argument("--license", required=True)
    ap.add_argument("--libraries", required=True,
                    help="运行期库文件名，逗号分隔（由构建脚本按实际平台命名给出）")
    args = ap.parse_args()

    stage = os.path.abspath(args.stage)
    outdir = os.path.abspath(args.outdir)
    os.makedirs(outdir, exist_ok=True)

    names = sorted(
        n for n in os.listdir(stage) if os.path.isfile(os.path.join(stage, n))
    )
    if not names:
        sys.exit("摊平目录是空的：" + stage)

    files = [
        {"name": n, "size": os.path.getsize(os.path.join(stage, n)),
         "sha256": sha256_file(os.path.join(stage, n))}
        for n in names
    ]
    libraries = [x for x in args.libraries.split(",") if x]
    missing = [x for x in libraries if x not in names]
    if missing:
        sys.exit("摊平目录里缺运行期库：" + " ".join(missing))

    component = {
        "component": args.component,
        "version": args.version,
        "sourceUrl": args.source_url,
        "sourceRef": args.source_ref,
        "sourceCommit": args.source_commit,
        "rid": args.rid,
        "license": args.license,
        "libraries": libraries,
        "files": files,
    }
    with open(os.path.join(stage, "component.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(component, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

    asset = "{}-{}.zip".format(args.component, args.rid)
    archive = os.path.join(outdir, asset)
    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as zf:
        for n in sorted(os.listdir(stage)):
            p = os.path.join(stage, n)
            if not os.path.isfile(p):
                continue
            info = zipfile.ZipInfo(n, date_time=FIXED_DATE)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            with open(p, "rb") as src:
                zf.writestr(info, src.read())

    record = dict(component)
    record.pop("files", None)
    record["asset"] = asset
    record["sha256"] = sha256_file(archive)
    record["bytes"] = os.path.getsize(archive)
    with open(os.path.join(outdir, "{}-{}.json".format(args.component, args.rid)), "w", encoding="utf-8", newline="\n") as f:
        json.dump(record, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

    print("  asset: {} ({} bytes, sha256 {})".format(asset, record["bytes"], record["sha256"][:16] + "…"))
    print("  files: " + " ".join(libraries))


if __name__ == "__main__":
    main()
