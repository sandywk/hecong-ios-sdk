// 桥契约常量 — 与 H5 侧 packages/link-sdk/src/app-bridge-constants.ts 的默认值严格对齐。
// 改任何一个值都必须两边一起改(桥协议 link-sdk-app-bridge.md;brand-neutrality.md:
// 品牌迁移日与 H5 的 env 注入一起走,单方改 = 桥断)。
//
// 跨 bundle 契约只用字符串(testing.md §2.2 同款纪律的原生版):这里没有任何"共享类型",
// 双方靠这些字符串在运行时对上号。

import Foundation

enum HecongBridgeConstants {
  /// 壳包版本(context.shellVersion,诊断/灰度用;发版时更新)
  static let shellVersion = "0.6.1"

  /// document-start 注入的 context 全局 key(桥协议 §二)
  static let contextKey = "__hecongAppContext"

  /// H5 装好的桥全局 key(壳经 evaluateJavaScript 调 send;桥协议 §三)
  static let bridgeKey = "__hecongLinkSDK"

  /// WKScriptMessageHandler 名(H5 → 壳反向通知;桥协议 §四)
  static let iosHandlerName = "hecongLinkSdk"

  /// UA 追加标识 — H5 的 APP_UA_PATTERN('Hecong-App|HecongLinkBridge')据此判宿主。
  /// 走 applicationNameForUserAgent 追加(保留系统默认 UA,不整串替换)。
  static let userAgentToken = "Hecong-App/\(shellVersion)"

  /// 壳声明给 H5 的能力(桥协议 §四 capabilities 协商;新能力只加声明字符串,永不改旧语义)。
  /// 'close':H5 标题栏画关闭键 → notify('close') → 壳退出(hh=1 无标题栏时 H5 天然不画)
  /// 'session-events':H5 把会话事件(消息到达/对话起止/网络)装进统一 `event` 信封发来,
  /// 壳转给宿主的通吃回调 + 常用具名回调。加新事件只动 H5 清单,壳零改动。
  /// 'header-style':H5 告诉壳"当前顶栏是深底还是浅底"→ 壳切状态栏图标黑白。
  /// 只在沉浸档有意义(标准档顶栏是原生的,壳自己知道颜色)。app-sdk-chat-entry.md §5.2
  static let capabilities = [
    "permission-gate", "badge", "download", "open-url", "close", "header", "session-events",
    "header-style",
  ]

  /// 桥协议 context 结构版本
  static let contextVersion = 1

  /// GlitchTip DSN(错误上报,app-sdk-plan.md §10.3)。**空 = 上报全链路 no-op,不炸**。
  ///
  /// 值与 H5 侧同一个自建 GlitchTip 项目(`scripts/brand-config.ts` glitchtipDsn 默认值)——
  /// **刻意同项目**:壳内 H5 的错误本来就报到这里,原生壳的错误跟它是同一条链路上下游,
  /// 分开两个项目反而要来回对着看。两者靠 `sdk` 标签区分(app-sdk-ios / link / web)。
  /// 明文无泄露顾虑的理由同 H5 侧(本仓不开源;DSN 只能写入不能读取)。
  static let errorDsn = "https://39f360035c524069bbf16994bf4d0029@beacon.aihecong.com/2"

  /// 上报环境标签(监控平台按它过滤)。同 H5「本地也上报,靠 environment 区分」的定案
  /// (brand-config.ts:121 owner 2026-07-27 拍板)。
  ///
  /// 🔴 **按构建类型自动区分,不写死**(0.1.1 修正:0.1.0 发出去时是写死的 "development",
  /// 等于线上租户的错误全被打上开发标签,与本地噪音混在一起 —— 上报做得再细也白搭)。
  /// 反过来写死 "production" 同样错:我们自己跑示范 APP 的错误会污染线上数据。
  /// 源码分发下这个宏取决于**租户编译时的构建配置**:他们 Debug 调试 → development,
  /// Release 上架 → production,正是我们想要的分界。
  static let errorEnvironment: String = {
    #if DEBUG
      return "development"
    #else
      return "production"
    #endif
  }()

  // MARK: - 本地骨架装载(2026-08-17 改版:APP 内置骨架 + 静态域拉插座,app-sdk-plan §二)

  /// ⚠️ 骨架页协议与主机名**一次定死永不改**:换 scheme/域 = 换 Web origin = localStorage
  /// 全部作废(Capacitor 生态换 scheme 的公开血泪;anonymousId 有 Keychain 镜像兜底,
  /// 其余本地状态无兜底)。host 必须是 localhost —— WKWebView 只对 localhost 主机名启用
  /// getUserMedia 等 secure-context API(Capacitor 文档论据,capacitorjs.com/docs/config)。
  static let localScheme = "hecongapp"
  static let localPageBase = "hecongapp://localhost/index.html"

  /// 线上静态域 link 插座固定路径(发版产物,短缓存 + 发版主动刷新;chunk 版本仍由后端
  /// config 的 sdk.version 指针控制 —— 跟版能力与"整页线上"形态完全一致)。
  /// 品牌值同本文件其余常量:迁移日与 H5 env 注入一起换。
  static let defaultLoaderUrl = "https://assets.aihecong.com/sdk/hecong-link.js"

  /// 后端 API 域,**仅用于骨架页的 `<link rel=preconnect>` 提前握手**(2026-08-27 首屏体验专项)。
  ///
  /// 为什么壳这边要单独写一份(H5 侧构建期已烘了 `LINK_API_BASE`):进站第一跳 config 就打这个域,
  /// 而插座是**远程 script** —— 等它下载执行完再插 preconnect,下一行就发 config 了,**零提前量**。
  /// 只有写在骨架 HTML 的 `<head>` 里,才能让「建连」跟「拉插座」并行跑掉。
  /// (对话链接落地页不吃这条:那边插座是内联的,插座里那份 preconnect 就够 ——
  /// 详 `link-loader-entry.ts` 的 `preconnect` 注释。)
  ///
  /// ⚠️ 这是一份**刻意接受的副本**,判据是「漂了会怎样」:preconnect 纯属提示,
  /// 域名过期/写错只是浪费一次空连接,**功能一个字节都不受影响**(与底色那种漂了就视觉穿帮的
  /// 性质完全不同,别套用那条墓碑)。品牌值迁移日与 [defaultLoaderUrl] 等常量一起换。
  static let defaultApiOrigin = "https://sdkapi.aihecong.com"

  /// 骨架 HTML(壳生成,免打包静态资源;loaderUrl 可被 config 覆盖供本地联调)。
  /// viewport-fit=cover 必带 —— H5 顶部安全区 env() 方案靠它才取到真值。
  /// 骨架本地承载永不失败,断网失败的是**插座 script** → onerror 经既有通知通道报壳
  /// (loader-error),壳画兜底页 + 重试(重载骨架即重拉插座)。
  /// 骨架页首帧垫色 —— **深色值只出现在这里的 CSS 里,壳不再在原生侧解析深浅色**
  /// (2026-08-20 重构,详 skeletonHtml)。深色取 H5 深色窗体底真值(theme-tokens-dark cGray0)。
  static let darkBackdrop = "#0d1117"
  static let lightBackdrop = "#ffffff"

  /// 骨架 HTML。
  ///
  /// 🔴 **底色由 CSS 媒体查询自己决定,不接受外部传入**(2026-08-20 重构,owner 两次实拍逼出来的)。
  ///
  /// 病根:原先壳在原生侧把"当前是深是浅"解析成固定色值再烘进这段 HTML。于是同一个问题
  /// 被拆成**三处各猜一次**(容器底色 / 骨架底色 / H5 自己),任何一处**判早了**(VC 还没继承到
  /// 宿主窗口 trait)或**判错源**(读了系统而非宿主 App)就会割裂:
  ///   · 顶栏与底部安全区两条黑边(容器猜深、页面画浅);
  ///   · **进页面先黑一下再跳浅色**(骨架猜深、H5 画浅)。
  /// 前两次修都是"让某一处猜得更准" —— 猜得再准也还是猜。
  ///
  /// 正解:**不解析**。CSS 的 `prefers-color-scheme` 由 WebView 在**真正绘制那一刻**求值,
  /// 且天然继承宿主的深浅色(含 App 用 `overrideUserInterfaceStyle` 强制的那种)——
  /// 与容器用的系统动态色 `.systemBackground` 同源,**结构上不可能不一致,也没有时机问题**。
  static func skeletonHtml(loaderUrl: String) -> String {
    return """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Chat</title>
    <link rel="preconnect" href="\(defaultApiOrigin)" crossorigin>
    <style>
    :root{color-scheme:light dark}
    html,body{margin:0;height:100%;background:\(lightBackdrop)}
    @media (prefers-color-scheme: dark){html,body{background:\(darkBackdrop)}}
    </style></head>
    <body><script src="\(loaderUrl)" onerror="webkit.messageHandlers.\(iosHandlerName).postMessage({type:'loader-error'})"></script></body></html>
    """
  }

  /// 预下载清单的文件名 —— 与 TS 侧 `shared-utils/src/prewarm-manifest-path.ts` 的
  /// `PREWARM_MANIFEST` **必须逐字一致**(跨语言契约只能靠纪律,同本文件其余桥常量)。
  static let prewarmManifestName = "prewarm.json"

  /// 预下载页 HTML(壳生成,只在**隐藏 WebView** 里跑)—— 2026-08-27 首屏体验专项。
  ///
  /// ## 它做什么 / 刻意不做什么
  ///
  /// **只下载,不执行。** 页面里没有一行业务 JS:先读渠道配置拿到当前 SDK 版本,再读版本目录里的
  /// 预下载清单,然后把首屏那几个文件 `fetch` 一遍 —— 让它们进 WebView 的 HTTP 缓存,**仅此而已**。
  /// 下载完的 JS **不会被当成脚本执行**(没有任何 `<script src>` 指向它们)。
  ///
  /// ## 🔴 为什么必须"只下载不执行"(整个方案的命门,别为"预热得更彻底"往里加执行)
  ///
  /// 一旦执行了聊天窗的 JS,就会连锁触发:领票 → 建 WS → 老访客走 `session.resume`,
  /// 而 resume 路径会让**后端把访客标成在线**。2026-08-27 与 api 仓会话交叉核实:
  /// 服务端 session 在 Redis 里 TTL **30 分钟**,「APP 被杀后 30 分钟内重启」正好命中 ⇒
  /// 工作台会闪一次假的"访客上线",而这恰恰是最常见的重启间隔(不是长尾)。
  /// 断开时又因 `onClose → onLeft` 按"人"定位,可能把该用户**另一条真实连接**误伤成离线。
  /// ⇒ 不执行 = 不领票 = 不连 WS = 上面这些一条都碰不到,同时白屏里最大的一块(下载)照样省掉。
  /// (后端侧结论读的是当时工作区状态,微信客服渠道专项提交后建议复核。)
  ///
  /// ## 收益边界 —— 它只治"第一次"
  ///
  /// WebView 的 HTTP 缓存**跨 APP 重启保留**(实测:杀掉 APP 重启后取同一文件 3ms / 传输 0 字节;
  /// 版本目录是 immutable 一年)。所以本页只在**两种时刻**有价值:①用户第一次用;②我们发新版后
  /// 第一次用。老用户日常打开时文件本就在缓存里 —— 那一段归「备用页保活」治,不归它。
  ///
  /// ## 失败无害
  ///
  /// 配置读不到 / 清单没有 / 版本对不上 / 网络断 → 就是没预下载成,照旧走正常加载流程。
  /// 不崩、不报错、不产生脏数据。故全程 `catch` 后静默,不上报(它不是故障,是"这次没赶上")。
  static func prewarmHtml(apiOrigin: String, cdnOrigin: String, channelId: String) -> String {
    return """
    <!doctype html><html><head><meta charset="utf-8"><title>p</title></head><body><script>
    (async () => {
      try {
        const cfgRes = await fetch('\(apiOrigin)/sdk/config/\(channelId)');
        if (!cfgRes.ok) return;
        const cfg = await cfgRes.json();
        const v = cfg && cfg.sdk && cfg.sdk.version;
        if (!v) return;
        // 显式判状态:清单不存在时对象存储回的是 XML 错误页,直接 .json() 会抛 ——
        // 虽然外层 catch 兜得住,但"靠解析失败来发现 404"不是意图明确的写法
        const mRes = await fetch('\(cdnOrigin)/sdk/v/' + v + '/\(prewarmManifestName)');
        if (!mRes.ok) return;
        const m = await mRes.json();
        // 清单里的 files 是**相对版本目录**的(清单自己就躺在那个目录下,版本号我们已经有了);
        // loader 是固定路径,相对 CDN 根。两者拼法不同,别混。
        const urls = [m.loader].concat((m.files || []).map((f) => 'sdk/v/' + v + '/' + f));
        // 并发拉:它们互不依赖,而且只是灌缓存,谁先谁后无所谓
        await Promise.all(urls.filter(Boolean).map((u) => fetch('\(cdnOrigin)/' + u).catch(() => {})));
      } catch (e) {
        // 失败无害:没预下载成而已,照旧走正常加载
      }
    })();
    </script></body></html>
    """
  }

  // 🔴 **进站占位转圈不在这里** —— 它由壳原生绘制,见 `HecongBootWaitView`。
  //
  // 曾经在这里写过一份纯 CSS 转圈(照官方对话链接落地页的做法),浏览器里验证完全正常,
  // **装进 APP 一帧都看不到**:WKWebView 在插座到货前根本不绘制任何内容(连满屏红块都不显示),
  // 骨架 HTML 里放什么都是白写。完整诊断过程记在 `HecongBootWaitView` 头注释,
  // **别再把占位挪回骨架 HTML**。
}
