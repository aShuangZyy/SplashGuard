# 开发笔记

## 环境

- 代码 / 规则 / Linux 侧测试：WSL2 Ubuntu 24.04
- Swift 工具链：官方 `swift-6.0.3-RELEASE-ubuntu24.04`（放在 `~/swift-toolchain`，
  见 `tools/_swift.sh`；`libncurses`/`libtinfo` 用 `~/swiftlib` 里的 symlink 补齐）
- 出包：GitHub Actions macOS runner
- 目标：iPhone 12 mini，iOS 14.2

## 已验证（Linux x86_64 + Swift 6.0.3，`-swift-version 5`）

`./tools/codec-test/run.sh`

| 项 | 结果 |
|---|---|
| 多级域名 / 超长标签 / AAAA 解析 | 全部正确，应答长度 38–103 字节 |
| 伪造应答 | `0.0.0.0` / `::`，flags `0x8180`，ANCOUNT=1 |
| IP/UDP 组包 | 总长、校验和、源目地址互换均正确 |
| 20 万条随机字节模糊测试 | 无崩溃、无越界 |

`./tools/rules-test/run.sh`

| 项 | 结果 |
|---|---|
| 规则加载 | 228,100 条后缀，39 ms（x86；A14 预计 15–30 ms） |
| 常驻内存增量 | +7.5 MB（mmap 表 + 偏移表） |
| 已知广告域名 | 33/33 拦截 |
| 常用正常域名 | 25/25 放行（无误杀） |
| 单次查询 | 命中 4.4 µs / 未命中 6.6 µs |

**未验证**：真机隧道建立、iOS 是否放行 `packet-tunnel-provider` entitlement、
扩展进程内存上限、真实 App 的拦截效果。这些只能上机。

## 关键实现决定

- **DNS 自己编解码**，不引第三方库：要改的只是 txid / flags / answer 段，
  自己写便于在 Linux 上用 swiftc 单测。
- **BlockList 用 mmap + 偏移表 + 二分**，不构造 `Set<String>`：
  22 万条字符串进 Set 要 10 MB+ 堆分配，扩展进程容易被 jetsam 杀掉；
  mmap 下常驻只看实际 fault-in 的页，查询只比对字节。
- **按后缀逐级匹配**而非整域匹配：广告域名带随机子域
  （`xxx-ad-sign.byteimg.com`），整域表会漏。
- **三层判定 + 强制拦截**：放行表必须覆盖图片 CDN（否则页面全白），
  但 CDN 里也混着广告位，用 `[Force]` 在放行之前把它们拦回来。
- **关键词按 UTF-8 字节比对**：最初直接 `host.contains(k)` 循环 288 次，
  单次 miss 要 162 µs；改成字节查表后降到 4–7 µs。
- **上游 txid 改写**：多个 App 同时用同一 txid 发查询会串包，
  对外查询分配独立 txid，应答回来再改回原值。
- **不设 default route**：`includedRoutes` 只放 `10.8.0.0/24` 和 `10.8.0.2/32`，
  DNS 设置单独指向 `10.8.0.2`。断连不断网。
- **VPNController 放 App/ 而非 Core/**：`NETunnelProviderManager` 在扩展里不可用，
  开 `APPLICATION_EXTENSION_API_ONLY` 后会编译报错。

## 踩过的坑

- `readPackets` 回调给的是 `Data`，不是 `[UInt8]`，直接传编译不过。
- `DNSWire.readName` 压缩指针跳转后，"下一个位置"必须用跳转前的原始偏移，
  否则多问题报文解析错位。
- 关键词判定一度排在放行表之后，`byteimg.com` 整棵子树放行把
  `p1-ad-sign.byteimg.com` 也放掉了 —— 判定次序本身就是功能。
- 顶层代码只允许出现在 `main.swift`，测试文件命名错了会报
  "expressions are not allowed at the top level"。

## 待办

- [ ] 真机验证隧道建立 + entitlement 是否放行
- [ ] 量扩展进程实际内存（目标 < 30 MB）
- [ ] TCP DNS 兜底（处理 TC=1 的截断应答）
- [ ] M2：规则热更新（从 GitHub raw 拉增量，替换 bin 后重启隧道）
- [ ] M3：可选启用 `NEFilterDataProvider` 做 URL 级补充

## 已定位：启动闪退的元凶是 `dynamic-codesigning`

真机实测（iOS 14.2 / iPhone 12 mini / TrollStore 安装），5 个只差 entitlement 的包：

| 包 | entitlement | 结果 |
|---|---|---|
| SGM1 | `get-task-allow` | 通过 |
| SGM2 | `get-task-allow` + `dynamic-codesigning` | **闪退** |
| SGM3 | `get-task-allow` + `networkextension` + `vpn.api` | 通过 |
| SGM4 | `get-task-allow` + `application-identifier` | 通过 |
| SGNoNE / SGNoExt | 上面全套 + `dynamic-codesigning` | 闪退 |

结论：
1. `dynamic-codesigning` 会让 App 在启动时被系统直接杀掉，fakesign + TrollStore 下不能带。
2. `com.apple.developer.networking.networkextension`（`packet-tunnel-provider`）和
   `com.apple.developer.networking.vpn.api`（`allow-vpn`）**在 TrollStore 下是被认的**，
   加上它们不影响启动 —— 这是 packet tunnel 方案可行的关键前提，已验证。
3. `application-identifier` 可以带，填自己的 bundle id 即可。
4. 排查手法：代码/资源完全相同、只改签名 entitlement 的对照包，是最快的二分方式。
