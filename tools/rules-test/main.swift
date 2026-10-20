// 验证规则表在真实数据下的命中率与内存占用（Linux）。
import Foundation

func rssMB() -> Double {
    guard let s = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else { return -1 }
    for line in s.split(separator: "\n") where line.hasPrefix("VmRSS") {
        let parts = line.split(separator: " ").compactMap { Double($0) }
        return parts.first.map { $0 / 1024 } ?? -1
    }
    return -1
}

let dir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "SplashGuard/Resources")
let e = RuleEngine.shared
let before = rssMB()
e.load(directory: dir)
let after = rssMB()
print("load: \(e.stats.loadMillis) ms  suffix=\(e.stats.suffixCount) keyword=\(e.stats.keywordCount) allowSubtree=\(e.allowSuffix.count) force=\(e.forceSuffix.count)")
print(String(format: "rss: %.1f MB -> %.1f MB (+%.1f)", before, after, after - before))

let ads = [
    // 国内
    "gdt.qq.com", "ad.toutiao.com", "p1-ad-sign.byteimg.com",
    "api-access.pangolin-sdk-toutiao.com", "ad.xiaomi.com",
    "sdk.e.qq.com", "mi.gdt.qq.com", "cpro.baidu.com",
    "atanx.alicdn.com", "log.mmstat.com", "ulogs.umeng.com",
    "splash.ixigua.com", "ad.wifi.com", "ad.kuaishou.com",
    "api.hypers.pangle.cn", "ad.oppo.com", "ad.vivo.com",
    "gromore.pangle.cn", "api.pangle.cn", "open.e.kuaishou.com",
    "ad.sina.com.cn", "sax.sina.com.cn",
    "click.huawei.com", "grs.hicloud.com", "adservice.google.com",
    // 海外
    "pagead2.googlesyndication.com", "googleads.g.doubleclick.net",
    "ad.doubleclick.net", "ads.applovin.com", "api.unityads.unity3d.com",
    "ads.vungle.com", "sdk.chartboost.com", "ads.inmobi.com",
]
let legit = [
    "api.weixin.qq.com", "www.apple.com", "api.bilibili.com",
    "www.zhihu.com", "www.baidu.com", "h5.ele.me",
    "m.taobao.com", "gw.alipayobjects.com", "i0.hdslb.com",
    "api.jpush.cn", "www.qq.com", "app.mi.com",
    "api.map.baidu.com", "passport.jd.com", "www.meituan.com",
    "api.weibo.cn", "sns.sinaimg.cn", "p3-sign.douyinpic.com",
    "img.hdslb.com", "s1.xhscdn.com", "static.maoyan.com",
    "res.wx.qq.com", "mmbiz.qpic.cn", "upos-sz-mirror.bilivideo.com",
    "api.ihuman.com",
]
func hit(_ list: [String]) -> (Int, [String]) {
    var bad: [String] = []
    var n = 0
    for h in list {
        if e.shouldBlock(host: h) { n += 1 } else { bad.append(h) }
    }
    return (n, bad)
}
let (ah, amiss) = hit(ads)
print("ads blocked \(ah)/\(ads.count)")
if !amiss.isEmpty { print("  未拦截:", amiss.joined(separator: ", ")) }
var lhit: [String] = []
for h in legit where e.shouldBlock(host: h) { lhit.append(h) }
print("legit passed \(legit.count - lhit.count)/\(legit.count)")
if !lhit.isEmpty { print("  误杀:", lhit.joined(separator: ", ")) }

// 查询耗时
var t = Date()
for _ in 0..<20000 { _ = e.shouldBlock(host: "api-access.pangolin-sdk-toutiao.com") }
print(String(format: "20k 次查询 %.1f ms", Date().timeIntervalSince(t) * 1000))
t = Date()
for _ in 0..<20000 { _ = e.shouldBlock(host: "www.example.org") }
print(String(format: "20k 次未命中 %.1f ms", Date().timeIntervalSince(t) * 1000))
