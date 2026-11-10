#!/usr/bin/env python3
"""源码优先：把 cannon-vendor.mk 里与 soong 模块撞车的原厂 blob 条目剔除。

规则来源：kati 的 `warning: overriding commands for target ...` ——
PRODUCT_COPY_FILES 的 copy 规则会覆盖 soong 的 install 规则，导致 A17 源码产物
被 A12 blob 顶掉（libbinder / libutils / bin/sh / codec2 ...）。

用法:
  python3 prune_blob_conflicts.py --dry-run     # 只打印
  python3 prune_blob_conflicts.py --apply       # 改写 cannon-vendor.mk
  python3 prune_blob_conflicts.py --list FILE   # 用给定清单（默认取构建日志）

被剔除的条目会集中追加到文件末尾的注释块，便于逐条回滚。
"""
import argparse
import os
import re
import sys

MK = "/cannon/rom/vendor/xiaomi/cannon/cannon-vendor.mk"
LOG = "/cannon/build.log"
MARK = "# ===== [src-over-blob] 以下原厂 blob 与 soong 源码模块同路径，已剔除 ====="
PROPRIETARY = "vendor/xiaomi/cannon/proprietary/"

# 需要保留 blob 的例外（Niclan 用 -v31 改名 + patchelf 解决，见 TODO）
KEEP = {
    "lib/libcodec2_vndk.so",
    "lib64/libcodec2_vndk.so",
    "lib/libcodec2_hidl@1.0.so",
    "lib64/libcodec2_hidl@1.0.so",
}


def targets_from_log(path):
    if not os.path.exists(path):
        sys.exit("找不到构建日志: %s" % path)
    pat = re.compile(r"overriding commands for target `out/target/product/cannon/vendor/([^']*)'")
    out = set()
    with open(path, "r", errors="replace") as f:
        for line in f:
            m = pat.search(line.replace("\x00", "").replace("\r", ""))
            if m:
                out.add(m.group(1))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--list")
    a = ap.parse_args()
    if not (a.apply or a.dry_run):
        ap.error("需要 --apply 或 --dry-run")

    if a.list:
        want = {l.strip() for l in open(a.list) if l.strip()}
    else:
        want = targets_from_log(LOG)
    want = {w for w in want if w not in KEEP}
    print("目标条目 %d（已排除 codec2 例外 %d）" % (len(want), len(KEEP)))

    lines = open(MK, "r", errors="replace").read().split("\n")
    kept, removed, i = [], [], 0
    dst_re = re.compile(r"\$\(TARGET_COPY_OUT_VENDOR\)/(\S+?)(?:\s|$)")
    while i < len(lines):
        line = lines[i]
        s = line.strip()
        cont = s.endswith("\\")
        body = s[:-1].strip() if cont else s
        src = dst = None
        if body and not body.startswith("#") and ":" in body and not body.startswith("PRODUCT_"):
            src, _, dst = body.partition(":")
            if not dst.startswith("$(TARGET_COPY_OUT_VENDOR)/"):
                src = None
        if src and src.startswith(PROPRIETARY):
            rel = dst.split("$(TARGET_COPY_OUT_VENDOR)/", 1)[1]
            if rel in want:
                removed.append((rel, src, cont))
                if not cont:
                    # 块尾：把它前面幸存行的续行符去掉
                    for k in range(len(kept) - 1, -1, -1):
                        if kept[k].strip():
                            if kept[k].rstrip().endswith("\\"):
                                kept[k] = kept[k].rstrip()[:-1].rstrip()
                            break
                i += 1
                continue
        kept.append(line)
        i += 1

    print("剔除 %d 条" % len(removed))
    if a.dry_run:
        for rel, src, _ in removed[:20]:
            print("  - %s" % rel)
        if len(removed) > 20:
            print("  ... 共 %d" % len(removed))
        return

    # 去掉文件末尾多余空行后追加注释块
    while kept and not kept[-1].strip():
        kept.pop()
    out = kept + ["", MARK]
    for rel, src, _ in sorted(removed):
        out.append("#   %s:%s$(TARGET_COPY_OUT_VENDOR)/%s" % (src, "", rel) if False else
                   "#   %s:$(TARGET_COPY_OUT_VENDOR)/%s" % (src, rel))
    out.append("# ===== [src-over-blob] end =====")
    with open(MK, "w") as f:
        f.write("\n".join(out) + "\n")
    print("已写入 %s" % MK)


if __name__ == "__main__":
    main()
