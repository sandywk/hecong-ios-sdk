// 备用聊天页(保活 + 预热)—— 2026-08-27,owner 反馈「点开客服空白一两秒,退出再进还是一样」。
//
// ## 这个东西解决什么
//
// 每次打开客服都是一次**完整冷启动**:建 WebView → 拉插座 → 问配置 → 拉聊天窗代码 → 领票 →
// 连 WS → 拉历史。HTTP 缓存只省得掉"下载",省不掉后面那一长串往返和 JS 重新执行 ——
// 这就是"退出再进还是一样慢"的原因(缓存缓的是**料**,不是**已经跑起来的窗口**)。
//
// 本池子持有**一个**已经跑起来的聊天页,下次打开直接端出来。
//
// ## 为什么"预热"和"保活"是同一个东西
//
// 原以为可以做一档更轻的预热(只提前握手 + 把代码下到缓存,不建 WebView)。**这条路不通**:
// WebView 用的是独立进程与独立网络栈,**壳这边用 URLSession 下载的东西它一个字节都用不上**
// (缓存与连接都不共享)。所以"提前准备好"只有一种实现 —— 真的建一个 WebView 跑起来。
// ⇒ 预热(提前造)与保活(用完留下)只是同一个池子的两个入口,不该做成两个功能。
// (「WebView 独立进程/独立网络栈」是平台架构的公开事实,非本仓实测。)
//
// ## 不显示的 WebView 真的能跑完整条链吗 —— 实测:能
//
// 2026-08-27 用一次性探针实测(孤立 WKWebView,**故意不 addSubview**):
// ```
// HCPROBE start inWindow=false superview=false   ← 不在任何窗口、无父视图
// t=1042ms  document complete,JS 已执行
// t=2042ms  聊天窗 DOM 已建好
// t=3042ms  内容渲染完成;此后 12s 稳定,未被系统冻结
// ```
// 同时这也是"会不会在租户 App 里露出来"的答案:**结构上不可能** —— 它根本没挂进视图树,
// 不是"挂了但藏起来"(那种才会因为某个 bug 露脸)。
//
// ⚠️ 用的全是公开 API(`WKWebView` + `load`),没有私有 API、没有绕过任何系统限制。
// 平台**没有**官方的"预热 WebView"能力,业界(腾讯 VasSonic / 美团 / Intercom 一类)
// 都是自己维护 WebView 池 —— 我们同款。这条是对两个平台 API 的认知,非本仓实测。

import UIKit
import WebKit

/// 备用聊天页池(单实例,只存**一个**)。
///
/// ## 🔴 安全闸门(全自动,租户零代码 —— 忘了调什么都不会出事)
///
/// 池子里装着**上一个访客的会话**,任何一条不守就是事故:
///
/// | 闸门 | 触发 | 不守会怎样 |
/// |---|---|---|
/// | 换人 | `resetUser()` / `identify` 换了 userId | **上一个会员的聊天记录给下一个人看**(§10.3.1 同款血泪) |
/// | 换渠道/换配置 | 签名不匹配 | 端出来的是另一个渠道的页面 |
/// | 内存吃紧 | 系统内存告警 | 跟宿主 App 抢内存,可能把它拖崩 |
/// | 渲染进程被杀 | `WebContentProcessDidTerminate` | 端出来是一片空白 |
/// | 放太久 | 超过 [ttl] | 会话过期/WS 早断,不如重来 |
///
/// ## 🔴 在线状态(比内存更容易被忽略的一条)
///
/// 保活 = "人已经离开聊天页,但 WebView 还活着"。若不告诉 H5,后端会一直认为**访客在线** ——
/// 客服端看到的在线状态是错的,离线推送 webhook 也永不触发
/// (病理与 `app-bridge-commands.ts` 的 `appLifecycle` 注释完全同源:心跳是 WS 层无条件自动
/// 应答,**不代表有人在看屏幕**)。
/// ⇒ 入池即发 `appLifecycle: background`,端出来发 `foreground`。**复用现成命令,零新增协议**。
@objc public final class HecongChatPool: NSObject {
  @objc public static let shared = HecongChatPool()

  private var vc: HecongChatViewController?
  private var signature: String?
  private var pooledAt: Date?
  /// 预下载用的临时 WebView(只灌缓存,跑完即弃;与备用页 [vc] 是两回事)
  private var downloader: WKWebView?

  /// 备用页最多留这么久。取 5 分钟:覆盖"退出后又想起一句话要问"这个真实高频场景,
  /// 又不至于让一个几十 MB 的 WebView 长期占着内存。超时后端出来的会话也多半要 resume,
  /// 收益已经不大。
  private let ttl: TimeInterval = 5 * 60

  private override init() {
    super.init()
    // 内存告警自动作废 —— **租户零代码**:这类系统事件由 SDK 自己订阅,不该出现在接入文档里
    // (租户"忘了调"就出事的设计本身就是错的)。
    NotificationCenter.default.addObserver(
      self, selector: #selector(onMemoryWarning),
      name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
  }

  // MARK: - 对外(供门面调用)

  /// 取一个能直接用的备用页;拿不到返回 nil(调用方照旧新建)。
  /// 命中时会自动喊 `foreground`(把在线状态喊回来)。
  func take(config: HecongChatConfig) -> HecongChatViewController? {
    guard let pooled = vc, let sig = signature, let at = pooledAt else { return nil }
    guard sig == Self.signature(of: config, userId: HecongChat.shared.currentUserId) else {
      drop(reason: "signature mismatch")
      return nil
    }
    guard Date().timeIntervalSince(at) <= ttl else {
      drop(reason: "ttl expired")
      return nil
    }
    // 还挂在某个导航栈里 = 没真正退出(极端时序),别端出来用
    guard pooled.parent == nil, pooled.presentingViewController == nil else { return nil }
    vc = nil
    signature = nil
    pooledAt = nil
    pooled.poolDidResume()
    return pooled
  }

  /// 用完归还。**入池即喊 background**(在线状态由此归位)。
  /// 已有备用页时丢掉旧的留新的(只存一个,新的那份状态更新)。
  func put(_ chat: HecongChatViewController, config: HecongChatConfig) {
    guard chat.isPoolable else { return } // 出过错/被判死的页面不留
    if vc !== chat { drop(reason: "replaced by newer") }
    chat.poolWillSuspend()
    vc = chat
    signature = Self.signature(of: config, userId: HecongChat.shared.currentUserId)
    pooledAt = Date()
  }

  /// 预下载首屏文件(门面 `HecongChat.prewarm()` 的落点)。
  ///
  /// 🔴 **只下载,不执行,不建备用页** —— 用一个临时隐藏 WebView 跑 `prewarmHtml`
  /// (那段 HTML 只 fetch 文件灌缓存,没有任何业务 JS),跑完即销毁。
  /// 为什么不能顺手把页面也跑起来:执行 JS 会连锁触发领票 → 建 WS → 老访客走 resume →
  /// **后端把访客标成在线**(工作台闪假上线),详 `HecongBridgeConstants.prewarmHtml` 注释。
  ///
  /// 缓存是**跨 WebView 共享**的(实测:A 下载 133ms,全新 B 取同一文件 3ms / 传输 0 字节),
  /// 所以这个临时 WebView 下完就能扔,真正打开时那个新 WebView 直接命中。
  ///
  /// 幂等:同一时刻只跑一个。失败无害(静默)。
  func prewarm(config: HecongChatConfig) {
    guard downloader == nil else { return }
    // CDN 根从 loaderUrl 推(它就是 `<cdn>/sdk/hecong-link.js`)—— 不另存一份域名副本
    guard let loader = URL(string: config.loaderUrl),
      let scheme = loader.scheme, let host = loader.host
    else { return }
    var cdn = "\(scheme)://\(host)"
    if let port = loader.port { cdn += ":\(port)" }

    let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    downloader = wv
    wv.loadHTMLString(
      HecongBridgeConstants.prewarmHtml(
        apiOrigin: HecongBridgeConstants.defaultApiOrigin,
        cdnOrigin: cdn,
        channelId: config.channelId),
      // baseURL 给 CDN 域:让页面里的 fetch 是同源请求,不吃 CORS
      baseURL: URL(string: cdn))
    // 给它一段时间把文件拉完就收工 —— 不常驻(常驻的是"备用页",那是另一回事)。
    // 30s:够 4G 上拉完首屏那几个文件,又不至于让一个隐藏 WebView 赖着不走。
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
      self?.downloader = nil
    }
  }

  /// 作废(幂等)。所有闸门最终都走这里。
  @objc public func drop(reason: String) {
    guard let old = vc else { return }
    vc = nil
    signature = nil
    pooledAt = nil
    old.destroy() // 走既有销毁链:断桥、停加载、摘监听
  }

  // MARK: - 闸门

  @objc private func onMemoryWarning() { drop(reason: "memory warning") }

  /// 身份变了 → 立刻作废。
  ///
  /// 🔴 **判据刻意粗**:只要身份**动过**就扔,不去比对"新旧是不是同一个人"。
  /// 理由:"这台设备绑过谁"那份事实的真源在 H5 的本地存储里,壳读不到也不该读一份副本
  /// (两份记同一件事、写入时机还不同 → 必然漂移,`resetUser` 注释已立此规矩)。
  /// 粗判的代价只是"多重建一次页面(慢一点)",细判判错的代价是**把上一个人的聊天记录
  /// 给下一个人看**。两者不对等,只能粗。
  @objc public func dropForIdentityChange() { drop(reason: "identity changed") }

  // MARK: - 签名

  /// 决定"这个备用页还能不能用给这次打开"。
  ///
  /// 只纳入**影响页面内容**的项:换了其中任何一个,H5 那边就是另一个页面。
  /// 纯壳侧 UI 项(title / 标题栏配色等)不纳入 —— 那些复用时由门面直接覆盖,不必重建页面。
  /// - Parameter userId: 门面当前登记的会员 ID(nil = 匿名)。**这是壳记的"我自己发出去过什么"**,
  ///   不是去猜 H5 里绑的是谁 —— 后者的真源在 H5 本地存储,壳读一份副本必然漂移(`resetUser` 立的规矩)。
  ///   纳入签名之后,「预热(匿名) → 用户登录 → 打开」这个典型流程会自然判定为不匹配并重建,
  ///   而「预热 → 直接打开」「登录后预热 → 打开」都能正常命中。
  static func signature(of c: HecongChatConfig, userId: String?) -> String {
    let query = c.extraQuery.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
      .joined(separator: "&")
    let routing = c.routing.map { "\($0.skillGroup)|\($0.fallback ?? "")|\($0.fallbackGroup ?? "")" }
      ?? ""
    // deviceId(宿主注入的匿名号种子)必须进签名:它变了就是换了个访客身份
    return [c.channelId, c.colorScheme, c.loaderUrl, c.deviceId ?? "", userId ?? "", routing, query]
      .joined(separator: "\u{1}")
  }
}
