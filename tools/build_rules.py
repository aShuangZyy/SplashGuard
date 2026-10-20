#!/usr/bin/env python3
"""把上游规则文本编译成运行时用的二进制表。

输入（--raw 目录）：
  antiad_surge.txt       DOMAIN-SUFFIX / DOMAIN / DOMAIN-KEYWORD
  antiad_domains.txt     纯域名，每行一个
  bm_ad_domain.list      DOMAIN-SUFFIX / DOMAIN-KEYWORD
  bm_advertising.list    同上

输出（--out 目录）：
  block_suffix.bin  后缀表
  block_exact.bin   精确表
  rules.module      [Allow] / [MITM] / [Rewrite]
  rules.meta.json   统计
"""
import argparse
import json
import os
import sys
from pathlib import Path

MAGIC = b"SGBL"
VERSION = 1

# 命中这些后缀的一律放行，避免把 App 的正常功能一起打掉
# 这些域名整棵子树放行：拦掉会直接导致 App 功能异常（图片/登录/支付/推送）。
# 其中混广告的子域，用下面的 FORCE 表在运行时重新拦回来。
ALLOW = [
    # Apple / 系统
    "apple.com", "icloud.com", "mzstatic.com", "cdn-apple.com", "apple-cloudkit.com",
    # 微信 / 支付
    "weixin.qq.com", "wechat.com", "weixin.com", "servicewechat.com",
    "alipay.com", "alipayobjects.com", "alipay.cn", "mclient.alipay.com",
    "unionpay.com", "unionpaysecure.com", "95516.com",
    # 推送
    "jpush.cn", "getui.com", "igexin.com",
    # 崩溃上报
    "bugly.qq.com", "crashlytics.com",
    # 对象存储 / 图片 CDN
    "myqcloud.com", "byteimg.com", "douyinpic.com", "hdslb.com",
    "alicdn.com", "sinaimg.cn", "pddpic.com", "kwimgs.com",
    "xhscdn.com", "360buyimg.com", "elemecdn.com", "qpic.cn",
    "gtimg.com", "bdimg.com", "bdstatic.com", "zhimg.com",
    # 友盟：推送与分析混用
    "umeng.com", "umengcloud.com",
    # 平台主域（子域里的广告由 FORCE 表拦）
    "taobao.com", "tmall.com", "jd.com",
    "meituan.com", "meituan.net", "dianping.com", "ele.me",
    "pinduoduo.com", "yangkeduo.com",
    "didiglobal.com", "xiaojukeji.com", "amap.com", "autonavi.com",
    "bilibili.com", "zhihu.com", "weibo.com", "weibo.cn", "sina.com.cn",
    "douyin.com", "ixigua.com", "kuaishou.com", "gifshow.com",
    "xiaohongshu.com", "baidu.com",
    "tencent.com", "qq.com",
    "netease.com", "126.net", "127.net", "163.com",
]

# 放行表压不住的广告子域：运行时优先于放行表判定
FORCE_SUFFIX = [
    "gdt.qq.com", "mi.gdt.qq.com", "e.qq.com", "sdk.e.qq.com", "ad.qq.com",
    "atanx.alicdn.com", "log.mmstat.com", "simba.taobao.com",
    "cpro.baidu.com", "eclick.baidu.com", "pos.baidu.com",
    "ulogs.umeng.com", "alog.umeng.com", "umengacs.m.taobao.com",
    "ad.toutiao.com", "splash.ixigua.com", "ad.xiaomi.com",
    "splash.douyin.com", "ad.kuaishou.com", "ad.bilibili.com",
    "open.e.kuaishou.com", "ad.sina.com.cn", "sax.sina.com.cn",
    "ad.oppo.com", "ad.vivo.com", "click.huawei.com", "ad.huawei.com",
]

# 广告 SDK 通用标识，出现在任何域名里都直接拦
EXTRA_KEYWORD = [
    "pangolin", "csjplatform", "-ad-sign", "adnxs",
    "applovin", "unityads", "vungle", "chartboost",
    "ironsrc", "inmobi", "adcolony", "mopub",
]


def norm_domain(value: str):
    v = value.strip().lower().rstrip(".")
    if not v or len(v) > 253:
        return None
    if v.startswith("*."):
        v = v[2:]
    if v.startswith("."):
        v = v[1:]
    if not v or "/" in v or " " in v:
        return None
    # 只保留 ASCII 域名，中文域名交给 punycode 上游处理
    try:
        v.encode("ascii")
    except UnicodeEncodeError:
        return None
    if "." not in v:
        return None
    return v


def parse_file(path: Path, suffix: set, exact: set, keyword: set):
    if not path.exists():
        return 0
    n = 0
    with path.open("r", encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            line = line.strip()
            if not line or line[0] in "#!;[":
                continue
            if "," in line:
                parts = [p.strip() for p in line.split(",")]
                kind = parts[0].upper()
                if len(parts) < 2:
                    continue
                if kind == "DOMAIN-SUFFIX":
                    d = norm_domain(parts[1])
                    if d:
                        suffix.add(d); n += 1
                elif kind == "DOMAIN":
                    d = norm_domain(parts[1])
                    if d:
                        exact.add(d); n += 1
                elif kind == "DOMAIN-KEYWORD":
                    k = parts[1].lower()
                    if k and len(k) >= 4:
                        keyword.add(k); n += 1
            else:
                d = norm_domain(line)
                if d:
                    suffix.add(d); n += 1
    return n


def drop_redundant(entries):
    """去掉「父域已在表内」的子域条目，可显著缩小体积。"""
    kept = []
    for d in entries:
        parts = d.split(".")
        redundant = False
        for i in range(1, len(parts) - 1):
            if ".".join(parts[i:]) in entries:
                redundant = True
                break
        if not redundant:
            kept.append(d)
    return kept


def write_table(path: Path, domains, label: str):
    data = sorted(domains, key=lambda s: s.encode("utf-8"))
    blob = bytearray()
    offsets = []
    for d in data:
        offsets.append(len(blob))
        raw = d.encode("utf-8")
        blob += len(raw).to_bytes(4, "little")
        blob += raw
    header = MAGIC + VERSION.to_bytes(4, "little") + len(data).to_bytes(4, "little")
    table = b"".join(o.to_bytes(4, "little") for o in offsets)
    path.write_bytes(header + table + bytes(blob))
    print(f"  {label}: {len(data)} 条, {path.stat().st_size / 1024:.0f} KB")
    return len(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", default="rules/vendor")
    ap.add_argument("--out", default="SplashGuard/Resources")
    args = ap.parse_args()

    raw = Path(args.raw)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    suffix, exact, keyword = set(), set(), set()
    total = 0
    for name in ["antiad_surge.txt", "antiad_domains.txt",
                 "bm_ad_domain.list", "bm_advertising.list"]:
        n = parse_file(raw / name, suffix, exact, keyword)
        print(f"  {name}: 读入 {n} 条")
        total += n
    if not suffix and not exact:
        print("没有读到任何规则，先把上游文件放进", raw, file=sys.stderr)
        return 1

    suffix -= set(ALLOW)
    exact -= set(ALLOW)
    keyword |= set(EXTRA_KEYWORD)

    print("去冗余前 suffix=%d exact=%d" % (len(suffix), len(exact)))
    suffix = set(drop_redundant(suffix))
    exact = {d for d in exact if d not in suffix}
    print("去冗余后 suffix=%d exact=%d keyword=%d" % (len(suffix), len(exact), len(keyword)))

    ns = write_table(out / "block_suffix.bin", suffix, "block_suffix")
    ne = write_table(out / "block_exact.bin", exact, "block_exact")

    module = ["# 自动生成，勿手改", "", "[Allow]"]
    module += ["*." + d for d in ALLOW]
    module += ["", "[Force]"]
    module += FORCE_SUFFIX
    module += ["", "[Rule]"]
    module += [f"DOMAIN-KEYWORD,{k}" for k in sorted(keyword)]
    module += ["", "[MITM]", "", "[Rewrite]"]
    (out / "rules.module").write_text("\n".join(module) + "\n", encoding="utf-8")

    meta = {
        "suffix": ns, "exact": ne, "keyword": len(keyword),
        "source_lines": total, "allow": len(ALLOW), "force": len(FORCE_SUFFIX),
    }
    (out / "rules.meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print("完成:", json.dumps(meta))
    return 0


if __name__ == "__main__":
    sys.exit(main())
