# SplashGuard

iOS 14 上的 DNS 层开屏广告拦截器。本地 VPN（`NEPacketTunnelProvider`）+ 内置广告域名表，
不代理任何真实流量，只接管 DNS 查询：命中黑名单的域名在本地回 `0.0.0.0`，其余原样转发。

- 目标设备：iPhone 12 mini / iOS 14.2
- 分发：TrollStore（需自签 entitlement，见下）
- 不做 TLS 中间人，不解析 HTTPS 内容

## 为什么只做 DNS 层

开屏广告和误触跳转广告的链路是：App 启动 → 请求广告位配置 → 拉素材 → 点击跳转。
这几步都依赖广告 SDK 的独立域名（`*.pangolin-sdk-toutiao.com`、`*.gdt.qq.com`、
`*.umeng.com`、各类 `*-ad-*.com`）。在 DNS 层把它解析成 `0.0.0.0`，SDK 请求直接失败，
App 走"无广告"分支，开屏图不出现，误触也就无从触发。

代价：无法处理与主站同域下发的广告（例如走 `api.xxx.com` 内部接口的广告位）。
那类需要 HTTPS 解密，属于 M3 之后的事。

## 结构

```
SplashGuard/
  App/                     宿主 App：开关 + 状态
  Core/                    BlockList（mmap 二分表）、RuleEngine（规则判定）
  Tunnel/                  PacketTunnelProvider、DNS 编解码、IP/UDP 组包、上游转发
  Resources/               编译好的规则（随包发布）
rules/
  vendor/                  上游规则源（不入库）
  curated/apps/            手写的按 App 补充规则
tools/
  build_rules.py           规则编译
  codec-test/              Linux 上验证 DNS/IP 编解码
```

## 本地构建

需要 macOS + Xcode 12+ 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open SplashGuard.xcodeproj
```

命令行出包（无签名）：

```bash
xcodebuild -project SplashGuard.xcodeproj -scheme SplashGuard \
  -sdk iphoneos -configuration Release \
  CODE_SIGNING_ALLOWED=NO build
```

## GitHub Actions 出 IPA

推 tag 即触发 `.github/workflows/build.yml`：macOS runner 上 `xcodegen` → `xcodebuild`
（关闭签名）→ 打 `Payload/` → `ldid -S` 伪签名 → 输出 `SplashGuard.ipa` artifact。

TrollStore 安装后需要用你自己的证书重签（TrollFools / ldid），因为
`packet-tunnel-provider` entitlement 必须由签名主体持有。

## 重新生成规则

```bash
python3 tools/build_rules.py --raw rules/vendor --out SplashGuard/Resources
```

规则源（不入库，自行下载）：

| 文件 | 来源 |
|---|---|
| `antiad_surge.txt` | ADgk Android ads filter |
| `antiad_domains.txt` | AdAway 系域名表 |
| `bm_ad_domain.list` | blackmatrix7 `Advertising_Domain` |
| `bm_advertising.list` | blackmatrix7 `Advertising` |

当前产物：228,100 条后缀、288 条关键词、69 条放行后缀、27 条强制拦截、5.9 MB。

## 规则的三层判定

查询一个域名时按顺序判断，命中即返回：

1. **强制拦截表**（`[Force]`，27 条）— 放行的大 CDN 里混着的广告位，
   如 `atanx.alicdn.com`、`gdt.qq.com`。
2. **关键词**（288 条）— 广告 SDK 标识，如 `pangolin`、`-ad-sign`。
   按字节在主机名里找，不经放行表。
3. **放行表**（`[Allow]`，69 条）— 图片 CDN、支付、推送这类拦了会坏功能的域名。
4. 最后才查 22 万条后缀黑名单。

放行优先于黑名单、但排在强制拦截和关键词之后 —— 这个次序很关键：
早期版本把关键词放在最后，导致 `p1-ad-sign.byteimg.com` 被 `byteimg.com` 放行漏掉。

## 已知限制

- 只覆盖 DNS 层；同域广告、客户端内置直连 IP 的广告打不掉。
- 上游 DNS 走 UDP，收到截断应答（TC=1）时客户端会改用 TCP 重试，隧道暂不处理 TCP DNS。
- 规则量大，误杀靠 `ALLOW_SUFFIX` 白名单兜底，遇到 App 功能异常优先往白名单里加。
