// 桥契约常量 — 与 H5 侧 packages/link-sdk/src/app-bridge-constants.ts 的默认值严格对齐。
// 改任何一个值都必须两边一起改(桥协议 link-sdk-app-bridge.md;brand-neutrality.md:
// 品牌迁移日与 H5 的 env 注入一起走,单方改 = 桥断)。
//
// 跨 bundle 契约只用字符串(testing.md §2.2 同款纪律的原生版):这里没有任何"共享类型",
// 双方靠这些字符串在运行时对上号。

import Foundation

enum HecongBridgeConstants {
  /// 壳包版本(context.shellVersion,诊断/灰度用;发版时更新)
  static let shellVersion = "0.1.3"

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
  static let capabilities = [
    "permission-gate", "badge", "download", "open-url", "close", "header", "session-events",
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

  /// 骨架 HTML(壳生成,免打包静态资源;loaderUrl 可被 config 覆盖供本地联调)。
  /// viewport-fit=cover 必带 —— H5 顶部安全区 env() 方案靠它才取到真值。
  /// 骨架本地承载永不失败,断网失败的是**插座 script** → onerror 经既有通知通道报壳
  /// (loader-error),壳画兜底页 + 重试(重载骨架即重拉插座)。
  /// 深色首帧垫色 = H5 深色窗体底真值(theme-tokens-dark cGray0)。仅垫 H5 接管前的首帧,
  /// 之后页面自身背景覆盖 —— 治"深色模式下打开闪白"
  static let darkBackdrop = "#0d1117"
  static let lightBackdrop = "#ffffff"

  static func skeletonHtml(loaderUrl: String, background: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Chat</title><style>html,body{margin:0;height:100%;background:\(background)}</style></head>
    <body><script src="\(loaderUrl)" onerror="webkit.messageHandlers.\(iosHandlerName).postMessage({type:'loader-error'})"></script></body></html>
    """
  }
}
