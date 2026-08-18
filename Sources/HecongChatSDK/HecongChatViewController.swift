// 壳主体:WKWebView 装本地骨架页 + 桥双通道 + 断网兜底(桥协议 link-sdk-app-bridge.md)。
//
// 装载形态 = **壳内本地骨架 + 静态域拉插座**(2026-08-17 改版,租户零域名接入;墓碑与原因链
// app-sdk-plan.md §二。⚠️ 本段曾写"装线上 link 页,不打包本地 HTML",2026-08-18 清理)。
// 老壳 × 新 H5 是常态 —— 通知分发 switch 必须有 default 空转(桥协议 §七,验收清单项)。

import UIKit
import WebKit

@objc(HecongChatViewController)
public final class HecongChatViewController: UIViewController, HecongChatCommandTarget {
  @objc public weak var delegate: HecongChatDelegate?

  private let config: HecongChatConfig
  private let idStore: HecongAnonymousIdStore
  private var webView: WKWebView?
  private var offlineView: UIView?
  /// 键盘布局所有权(壳缩 WebView 到键盘上方,细节见 HecongKeyboardLayoutGuard 头注释)
  private var keyboardGuard: HecongKeyboardLayoutGuard?
  /// H5 ready 前排队的命令(ready 后按序补发;页面重载会重新进入排队态)
  private var isBridgeReady = false
  /// 上次同步给聊天页的深浅色档位,避免同一档位重复下发
  private var lastSyncedScheme: String?
  private var pendingCommands: [[String: Any]] = []

  @objc public init(config: HecongChatConfig) {
    self.config = config
    self.idStore = HecongAnonymousIdStore(scope: config.anonymousIdScope)
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("use init(config:)") }

  // MARK: - 生命周期

  public override func viewDidLoad() {
    super.viewDidLoad()
    // 深色首帧不闪白:容器 + WebView 双层垫色跟当前解析出的档位(auto 用 systemBackground
    // 天然跟系统),骨架 body 同色三层兜齐,H5 接管后被页面背景覆盖
    view.backgroundColor = config.colorScheme == "auto"
      ? .systemBackground
      : (resolvedColorScheme() == "dark"
        ? backdropColor(HecongBridgeConstants.darkBackdrop) : .white)
    setupWebView()
    observeAppLifecycle()
    load()
    // 登记到门面 + 重放门面已登记的身份(租户可能在打开本页之前就 identify 过,§10.1)
    HecongChat.shared.attachTarget(self)
  }

  private func backdropColor(_ hex: String) -> UIColor {
    var value: UInt64 = 0
    Scanner(string: String(hex.dropFirst())).scanHexInt64(&value)
    return UIColor(
      red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255, alpha: 1)
  }

  /// 首帧垫色(骨架 body + WebView 透明层共用):按解析出的档位;auto 按当前系统深浅
  private func resolvedBackdrop() -> String {
    return resolvedColorScheme() == "dark"
      ? HecongBridgeConstants.darkBackdrop : HecongBridgeConstants.lightBackdrop
  }

  /// 销毁:摘 message handler(WKUserContentController 强持有 handler,不摘 = 经典泄漏)
  /// + 尽力通知 H5 拆桥。VC 释放即 WebView 释放,页面随之销毁,WS 由系统关闭。
  @objc public func destroy() {
    HecongChat.shared.detachTarget(self)
    cancelReadyWatchdog()
    guard let wv = webView else { return }
    wv.evaluateJavaScript(
      "window.\(HecongBridgeConstants.bridgeKey)&&window.\(HecongBridgeConstants.bridgeKey).destroy()",
      completionHandler: nil)
    wv.configuration.userContentController.removeScriptMessageHandler(
      forName: HecongBridgeConstants.iosHandlerName)
    wv.stopLoading()
    wv.navigationDelegate = nil
    webView = nil
    NotificationCenter.default.removeObserver(
      self, name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.removeObserver(
      self, name: UIApplication.willEnterForegroundNotification, object: nil)
    endBackgroundTask()
  }

  deinit { destroy() }

  // MARK: - 公共命令面(壳 → H5,桥协议 §三;ready 前调用自动排队)

  @objc public func identify(userId: String, profile: [String: Any]?, data: [String: Any]?) {
    var payload: [String: Any] = ["userId": userId]
    if let profile = profile { payload["profile"] = profile }
    if let data = data { payload["data"] = data }
    send(["type": "identify", "payload": payload])
  }

  @objc public func updateUser(profile: [String: Any]?, data: [String: Any]?) {
    var payload: [String: Any] = [:]
    if let profile = profile { payload["profile"] = profile }
    if let data = data { payload["data"] = data }
    send(["type": "userUpdate", "payload": payload])
  }

  @objc public func resetUser() {
    send(["type": "userReset"])
  }

  /// 手动指定深浅色。默认档(`host`)已经自动跟随 APP,**一般不需要调这个** ——
  /// 只有宿主想临时压一个档位(例如页面内的独立开关)时才用。
  @objc public func setColorScheme(_ scheme: String) {
    send(["type": "setColorScheme", "payload": ["scheme": scheme]])
  }

  // MARK: - WebView 装配

  private func setupWebView() {
    let conf = WKWebViewConfiguration()
    // 宿主标准坑 checklist(sdk-public-api-contract.md §八):不设 inline = 视频被系统全屏
    // 播放器接管;不清 userAction = 自动播放场景失效
    conf.allowsInlineMediaPlayback = true
    conf.mediaTypesRequiringUserActionForPlayback = []
    // UA 追加(不整串替换,保留 Safari 默认 UA)—— H5 APP_UA_PATTERN 据此判宿主,与 context 互为冗余
    conf.applicationNameForUserAgent = HecongBridgeConstants.userAgentToken
    // document-start 注入 context(先于页面脚本,桥协议 §二 时序硬要求)
    conf.userContentController.addUserScript(
      WKUserScript(
        source: buildContextScript(), injectionTime: .atDocumentStart, forMainFrameOnly: true))
    // 本地骨架页承载(装载形态 2026-08-17 改版,详 HecongLocalSchemeHandler 头注释)
    conf.setURLSchemeHandler(
      HecongLocalSchemeHandler(loaderUrl: config.loaderUrl, background: resolvedBackdrop()),
      forURLScheme: HecongBridgeConstants.localScheme)
    // H5 → 壳反向通知通道(weak proxy 断开 userContentController → handler → VC 的持有环)
    conf.userContentController.add(
      WeakScriptMessageHandler(self), name: HecongBridgeConstants.iosHandlerName)

    let wv = WKWebView(frame: view.bounds, configuration: conf)
    // WebView 首帧透明 → 透出容器垫色(WKWebView 默认不透明白底 = 深色闪白的来源)
    wv.isOpaque = false
    wv.backgroundColor = .clear
    // 高度不走 autoresizing —— 键盘所有权归 keyboardGuard 全权铺 frame(旋转经 viewDidLayoutSubviews)
    wv.navigationDelegate = self
    if #available(iOS 16.4, *) { wv.isInspectable = true }
    // 聊天输入不要系统表单辅助条(上下箭头/完成),细节见 HecongInputAccessoryRemover
    HecongInputAccessoryRemover.remove(from: wv)
    view.addSubview(wv)
    webView = wv
    keyboardGuard = HecongKeyboardLayoutGuard(
      hostView: view, webView: wv,
      topInset: { [weak self] in
        guard let self = self else { return 0 }
        // 有原生导航栏 → 避开(状态栏 + 导航栏);无 → 铺满,状态栏由 H5 env 自理
        return self.navigationController?.isNavigationBarHidden == false
          ? self.view.safeAreaInsets.top : 0
      })
  }

  public override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    keyboardGuard?.hostDidLayout()
  }

  /// 聊天页可见期间暂停门面的未读轮询 —— 此刻 WS 是权威来源(§10.2),两个源同时跑会打架。
  /// 未开未读跟踪的租户(默认档)这两行是空转,零开销。
  public override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    HecongChat.shared.setChatVisible(true)
  }

  public override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    HecongChat.shared.setChatVisible(false)
  }

  // MARK: - APP 前后台联动(桥协议 §六)

  /// 让 close 帧发得出去的一小段后台执行时间(几百毫秒级,发完即还)。
  private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

  /// 订阅 APP 前后台。**用 didEnterBackground,不是 willResignActive** —— 后者在下拉控制
  /// 中心、来电横幅、切到 App Switcher 预览时都会触发,而**用户并没有离开**,那时断连
  /// = 人还在却被判离线。安卓侧对等选择是 onStop 而非 onPause(HecongChatView.onHostStop)。
  private func observeAppLifecycle() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(hostDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(hostWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
  }

  /// 进后台:主动断连,让后端秒级判离线(否则要等心跳超时约一分钟,这期间客服回的消息
  /// 不会触发离线推送 webhook —— 详 H5 侧 `LinkSdk.setAppLifecycle` 头注释)。
  ///
  /// **为什么要申请后台执行时间**:`didEnterBackground` 之后 WKWebView 的 WebContent 进程
  /// 随时可能被系统挂起,`evaluateJavaScript` 是异步的 —— 不占住这几百毫秒,断开帧很可能
  /// 压根没发出去,iOS 侧就退化成"看运气"。这不是"后台保活":范围是一条命令、有明确终止
  /// 条件(JS 执行完即还),跟"我们不做后台保活"是两回事。
  @objc private func hostDidEnterBackground() {
    guard webView != nil else { return }
    beginBackgroundTask()
    send(lifecycleCommand("background")) { [weak self] in
      self?.endBackgroundTask()
    }
  }

  @objc private func hostWillEnterForeground() {
    guard webView != nil else { return }
    send(lifecycleCommand("foreground"))
  }

  private func lifecycleCommand(_ state: String) -> [String: Any] {
    ["type": "appLifecycle", "payload": ["state": state]]
  }

  private func beginBackgroundTask() {
    endBackgroundTask() // 上一次没还干净(极短时间内连续切)→ 先还,不叠加
    backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "hecong.chat.leave") {
      // 系统提前收回(时间到)→ 必须自己结束,否则会被强杀
      self.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTaskId != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTaskId)
    backgroundTaskId = .invalid
  }

  /// 宿主自绘标题栏的返回键接入(2026-08-18 补;安卓 `handleBackPressed` 的 iOS 对等物)。
  ///
  /// 返回 true = 本视图消费了这次返回(H5 里有可关的覆盖层:图片预览 / 浮层 / 面板)——
  /// H5 的 NavStack 把"可返回层"物化成 history entry(nav-stack.md §2.2),壳只做
  /// "返回 → history back"的翻译,**不新增桥命令**,老 H5 天然工作;
  /// false = 无可关层,宿主自行 pop / dismiss。
  ///
  /// ⚠️ 用宿主自己的原生导航栏(标准 push 形态)时不需要调 —— 那条链路由系统返回键走,
  /// H5 层由 CloseWatcher 自理。**只有自绘标题栏 / 自定义返回按钮才必须接**,
  /// 不接的症状:图片预览开着时点返回直接退出整个客服页(而不是只关预览)。
  @objc public func handleBackPressed() -> Bool {
    guard let wv = webView, wv.canGoBack else { return false }
    wv.goBack() // → popstate → H5 NavStack 关栈顶层(逐层剥离,与浏览器行为完全同构)
    return true
  }

  /// 重新加载(宿主自定义兜底 UI 时用;壳内置兜底页的"重试"按钮走同一入口)
  @objc public func retry() {
    load()
  }

  @objc private func load() {
    offlineView?.removeFromSuperview()
    offlineView = nil
    isBridgeReady = false
    startReadyWatchdog()
    webView?.load(URLRequest(url: skeletonPageUrl()))
  }

  // MARK: - 桥 ready 看门狗(把"沉默"变成可上报的事件)

  /// 🔴 **唯一能发现"白屏"类故障的手段**(owner 2026-08-18 提出把上报做细)。
  ///
  /// 为什么必须有:骨架页是本地承载,**永远"加载成功"**;插座 script 拉不下来有
  /// `loader-error` 兜着。但**夹在中间的那一大段全是哑的** —— 插座下来了却拉不动 chunk、
  /// config 被限流/封号、token 401、H5 初始化抛异常……任何一环出问题,用户看到的都是
  /// 一片空白,而壳这边**收不到任何信号**(导航成功、script onerror 没触发、桥也没挂上)。
  /// 结果就是"线上一直有人打不开客服,我们一无所知"。看门狗把这段沉默变成一条上报。
  ///
  /// **刻意只上报、不画兜底页**:超时 ≠ 失败(弱网下 H5 可能就是慢),画兜底会把一个
  /// 马上要成功的会话打断。判"真失败"仍归 loader-error / 导航失败那两条既有链路。
  private var readyWatchdog: DispatchWorkItem?

  /// 20s:够慢网跑完"插座 → chunk → config → token → 建连"整条链,又不至于让真故障
  /// 拖太久才留痕。取值凭据:H5 侧 token 请求本身就有 10s 超时(sdk-http),留一倍余量。
  private static let readyWatchdogTimeout: TimeInterval = 20

  private func startReadyWatchdog() {
    cancelReadyWatchdog()
    let task = DispatchWorkItem { [weak self] in
      guard let self = self, !self.isBridgeReady else { return }
      // 已经画了兜底页 = 失败已由既有链路报过,不重复上报(去重靠签名只能挡同一条)
      guard self.offlineView == nil else { return }
      HecongErrorReporter.shared.report(
        scope: "load",
        message: "bridge never became ready within \(Int(Self.readyWatchdogTimeout))s",
        channelId: self.config.channelId,
        extra: ["loader_url": self.config.loaderUrl])
    }
    readyWatchdog = task
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.readyWatchdogTimeout, execute: task)
  }

  private func cancelReadyWatchdog() {
    readyWatchdog?.cancel()
    readyWatchdog = nil
  }

  /// 骨架页 URL:虚拟域 + ?c=渠道 ID + extraQuery;query 形态与对话链接完全同链
  /// (H5 既有 ?c=/?hh=/?lang= 解析零改动)。hh 缺省自动 1(APP 有原生导航,H5 不画标题栏)。
  private func skeletonPageUrl() -> URL {
    var parts = URLComponents(string: HecongBridgeConstants.localPageBase)!
    var items = [URLQueryItem(name: "c", value: config.channelId)]
    for (k, v) in config.extraQuery { items.append(URLQueryItem(name: k, value: v)) }
    if !items.contains(where: { $0.name == "hh" || $0.name == "hideHeader" }) {
      items.append(URLQueryItem(name: "hh", value: "1"))
    }
    parts.queryItems = items
    return parts.url!
  }

  /// context 注入脚本(桥协议 §二)。墓碑(2026-08-17):曾带凭据字段 bundleId/appPlatform
  /// (包名白名单校验)→ 议题当天关闭删除(客户端自报不可验真,零防护价值),别复活。
  private func buildContextScript() -> String {
    var ctx: [String: Any] = [
      "v": HecongBridgeConstants.contextVersion,
      "shellVersion": HecongBridgeConstants.shellVersion,
      "capabilities": HecongBridgeConstants.capabilities,
    ]
    // 深浅色档位语义(theming §7.3.1 三档链):context 注入 = **显式声明**,会压过渠道 config。
    // ⚠️ 墓碑:曾把 **auto** 解析成具体值注入 → 渠道配 dark 被壳压回浅色。auto 必须零注入;
    // 想"跟随宿主"用 host 档(默认),两者语义不同,别再合并。
    if let explicit = explicitScheme() { ctx["colorScheme"] = explicit }
    // 镜像优先于宿主 deviceId 种子:镜像 = 跟随 H5 真源的最新生效号,永远最准(§二.2)
    if let anon = idStore.read() ?? config.deviceId { ctx["anonymousId"] = anon }
    guard let data = try? JSONSerialization.data(withJSONObject: ctx),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return "window.\(HecongBridgeConstants.contextKey)=\(json);"
  }

  /// 要注入给 H5 的**显式**档位;nil = 不注入(把决定权交回渠道 config)。
  /// host(默认档)在这里落成具体值 —— 这正是"聊天页跟随 APP"零代码生效的地方。
  private func explicitScheme() -> String? {
    switch config.colorScheme {
    case "light", "dark": return config.colorScheme
    case "auto": return nil
    default: return hostIsDark() ? "dark" : "light" // host(默认)与未知值都按跟随宿主处理
    }
  }

  private func resolvedColorScheme() -> String {
    explicitScheme() ?? (hostIsDark() ? "dark" : "light")
  }

  private func hostIsDark() -> Bool {
    if #available(iOS 13.0, *) { return traitCollection.userInterfaceStyle == .dark }
    return false
  }

  /// 宿主深浅色变了 → 默认档(`host`)自动把新档位同步给聊天页,接入方零代码。
  ///
  /// ⚠️ `auto` 档刻意不跟(那是"渠道后台说了算"的语义,跟了就把后台配置压掉了 —— 墓碑见
  /// contextScript);`light`/`dark` 是宿主显式指定,更不该被系统改掉。
  public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
    super.traitCollectionDidChange(previous)
    guard config.colorScheme != "auto", config.colorScheme != "light",
      config.colorScheme != "dark" else { return }
    if #available(iOS 13.0, *) {
      guard traitCollection.userInterfaceStyle != previous?.userInterfaceStyle else { return }
    }
    let next = hostIsDark() ? "dark" : "light"
    guard next != lastSyncedScheme else { return }
    lastSyncedScheme = next
    setColorScheme(next)
  }

  // MARK: - 命令下发

  private func send(_ command: [String: Any], completion: (() -> Void)? = nil) {
    guard isBridgeReady, let wv = webView else {
      pendingCommands.append(command)
      completion?()
      return
    }
    guard let data = try? JSONSerialization.data(withJSONObject: command),
      let json = String(data: data, encoding: .utf8)
    else {
      completion?()
      return
    }
    // completionHandler 在 JS 真的执行完之后回调 —— 进后台那条命令靠它判断"已经喊到了",
    // 才能安全结束后台任务(见 hostDidEnterBackground)。
    let commandType = (command["type"] as? String) ?? "unknown"
    // 表达式取值成 true/false:桥不在(被拆 / 页面换了)时为 false —— 命令悄悄丢了。
    // 光看 `error` 抓不到这种情况(求值出 undefined 不算 JS 异常),与安卓侧写法对齐。
    wv.evaluateJavaScript(
      "!!(window.\(HecongBridgeConstants.bridgeKey)&&window.\(HecongBridgeConstants.bridgeKey).send(\(json)))",
      completionHandler: { [weak self] result, error in
        // 命令没送到 = 租户以为绑了身份/切了主题,实际什么都没发生 —— 必须留痕,
        // 否则只能等租户来问"我 identify 了怎么没生效"(owner 2026-08-18:上报做细)。
        // ⚠️ **只报命令名,绝不报 payload** —— payload 里有会员 ID 与资料(§10.3 隐私清单)。
        let delivered = (result as? NSNumber)?.boolValue ?? false
        if error != nil || !delivered {
          HecongErrorReporter.shared.report(
            scope: "bridge", message: "command '\(commandType)' not delivered",
            channelId: self?.config.channelId,
            extra: ["error": error?.localizedDescription ?? "bridge absent"])
        }
        completion?()
      })
  }

  // MARK: - H5 → 壳通知分发(桥协议 §四)

  fileprivate func handleNotification(_ body: Any) {
    guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return }
    let payload = dict["payload"] as? [String: Any]
    switch type {
    case "ready":
      // 生效号回写镜像(§二.2 第 2 条:壳收到一律持久化覆盖)+ 透给宿主(§10.5 推送闭环)
      if let anon = payload?["anonymousId"] as? String, !anon.isEmpty { adoptAnonymousId(anon) }
      // apiBase 缓存供未读跟踪(app-sdk-plan.md §10.2:壳不另立配置,H5 下发是唯一来源)
      if let apiBase = payload?["apiBase"] as? String, !apiBase.isEmpty {
        HecongChat.shared.cacheApiBase(apiBase)
      }
      isBridgeReady = true
      cancelReadyWatchdog()
      let queued = pendingCommands
      pendingCommands = []
      queued.forEach { send($0) }
      delegate?.hecongChatReady?()
    case "anonymousIdChanged":
      if let anon = payload?["anonymousId"] as? String, !anon.isEmpty { adoptAnonymousId(anon) }
    case "header-identity":
      // 宿主自绘标题栏(桥协议 §四):字段全可选,原样透传,壳不加工
      let identity = HecongHeaderIdentity(
        nickname: payload?["nickname"] as? String,
        avatar: payload?["avatar"] as? String,
        signature: payload?["signature"] as? String,
        source: payload?["source"] as? String,
        pending: (payload?["pending"] as? Bool) ?? false)
      HecongChat.shared.applyHeaderIdentity(identity)
      notifyOwnDelegate { $0.hecongChatHeaderIdentityDidChange?(identity) }
    case "identified":
      if let userId = payload?["userId"] as? String { delegate?.hecongChatDidIdentify?(userId) }
    case "user-reset":
      delegate?.hecongChatDidResetUser?()
    case "unread":
      // 聊天页开着时 WS 是权威来源 → 同步喂门面(轮询此刻是暂停的,不会打架,§10.2)
      if let count = payload?["count"] as? Int {
        HecongChat.shared.applyUnread(count) // 门面内部会回调 HecongChat.shared.delegate
        notifyOwnDelegate { $0.hecongChatUnreadDidChange?(count) }
      }
    case "open-url":
      if let raw = payload?["url"] as? String, let url = URL(string: raw) {
        if delegate?.hecongChat?(handleOpenUrl: url) != true { openExternally(url) }
      }
    case "download":
      if let raw = payload?["url"] as? String, let url = URL(string: raw) {
        let filename = payload?["filename"] as? String
        if delegate?.hecongChat?(handleDownload: url, filename: filename) != true {
          openExternally(url)
        }
      }
    case "event":
      // 会话事件信封(capability 'session-events'):具名回调 + 通吃,详 HecongSessionEvents
      HecongSessionEvents.dispatch(payload) { action in
        if let facade = HecongChat.shared.delegate { action(facade) }
        notifyOwnDelegate(action) // 与门面同一对象时跳过,避免同一件事回调两次
      }
    case "loader-error":
      // 骨架里插座 script 拉取失败(断网/静态域不可达)→ 原生兜底页(骨架形态下
      // didFailProvisionalNavigation 不会触发 —— 骨架是本地承载永远"导航成功")
      showOfflineView(reason: "loader script failed to load")
    case "close":
      // H5 标题栏 ✕(壳声明 'close' 才画):宿主可拦截自管;默认按呈现形态退出
      if delegate?.hecongChatDidRequestClose?() != true {
        if presentingViewController != nil, navigationController?.viewControllers.count ?? 1 <= 1 {
          dismiss(animated: true)
        } else {
          navigationController?.popViewController(animated: true)
        }
      }
    case "permission-request":
      guard let requestId = payload?["requestId"] as? String,
        let kind = payload?["kind"] as? String
      else { return }
      HecongPermissionResolver.resolve(kind: kind) { [weak self] granted in
        self?.send([
          "type": "permissionResult",
          "payload": ["requestId": requestId, "granted": granted],
        ])
      }
    default:
      // 双向兼容铁律:未知通知无视不崩(新 H5 加新通知,老壳空转;桥协议 §七 验收清单项)。
      // 但**留痕** —— 这是"新 H5 × 老壳"错配的唯一可观测信号,静默丢弃等于放弃诊断能力。
      // 不影响任何行为,上报器自带去重 + 单次会话 20 条上限,刷不爆(§10.3 限流)。
      HecongErrorReporter.shared.report(
        scope: "bridge", message: "unknown notification type '\(type)'",
        channelId: config.channelId,
        extra: ["shell_version": HecongBridgeConstants.shellVersion])
    }
  }

  /// 生效号落地:镜像持久化 + 透给宿主(推送闭环 §10.5)。两个触发点(ready / anonymousIdChanged)
  /// 共用,避免"只写镜像忘了回调"的漏接。
  private func adoptAnonymousId(_ anonymousId: String) {
    idStore.write(anonymousId)
    HecongChat.shared.notifyAnonymousIdChanged(anonymousId) // 门面内部会回调它自己的 delegate
    notifyOwnDelegate { $0.hecongChatDidChangeAnonymousId?(anonymousId) }
  }

  /// 回调本 VC 自己的 delegate,**但跳过与门面 delegate 同一个对象的情形**。
  ///
  /// 为什么需要:未读 / 匿名号这两件事**门面与视图都会报**(门面服务于"没打开聊天页"的场景,
  /// 视图服务于"只用视图不用门面"的场景)。租户常把同一个对象两边都设 —— 不去重就是
  /// **同一个回调触发两次**(未读角标闪两下 / 匿名号重复上报)。身份比较是最省事且不漏的去重法。
  private func notifyOwnDelegate(_ block: (HecongChatDelegate) -> Void) {
    guard let own = delegate else { return }
    if own === HecongChat.shared.delegate { return }
    block(own)
  }

  /// 打开外链。**白名单必须含 tel/mailto/sms**(2026-08-18 专项排查抓出的静默黑洞)。
  ///
  /// 🔴 病根:H5 侧 `openExternalUrl` 是「壳接管了就不再自理」——
  /// `if (opener?.(url)) return; window.open(...)`,而壳的 opener **无条件返回 true**。
  /// 只要壳声明了 'open-url' 能力,**所有**外链都归壳,H5 不再兜底。老写法只放行 http(s),
  /// 于是客服发的电话号码 / 邮箱链接(`tel:` `mailto:`)在 APP 里**点了完全没反应** ——
  /// 同一条消息在 Safari 和对话链接里能正常唤起拨号/邮件。客服报电话是高频场景。
  ///
  /// 仍拒绝 `javascript:` `file:` 等借道 scheme,但**拒绝要留痕**(上报),不再静默丢弃。
  private static let allowedSchemes: Set<String> = ["http", "https", "tel", "mailto", "sms", "geo"]

  private func openExternally(_ url: URL) {
    let scheme = url.scheme?.lowercased() ?? ""
    guard Self.allowedSchemes.contains(scheme) else {
      HecongErrorReporter.shared.report(
        scope: "open-url", message: "blocked scheme: \(scheme)", channelId: config.channelId)
      return
    }
    UIApplication.shared.open(url, options: [:]) { [weak self] ok in
      guard !ok, let self = self else { return }
      // 系统没有 App 能处理(如 iPad 无电话)→ 留痕,别静默
      HecongErrorReporter.shared.report(
        scope: "open-url", message: "system refused scheme: \(scheme)",
        channelId: self.config.channelId)
    }
  }

  // MARK: - 断网兜底(app-sdk-plan.md §二:壳给"网络不可用"页 + 重试)

  /// - Parameter reason: 失败原因(上报 + 透给宿主;不含任何隐私数据,§10.3)
  private func showOfflineView(reason: String = "load failed") {
    // 只报一次(offlineView 已在 = 同一次失败的重复回调),同时透给宿主自行上报/换 UI
    guard offlineView == nil else { return }
    HecongErrorReporter.shared.report(
      scope: "load", message: reason, channelId: config.channelId)
    delegate?.hecongChatDidFailToLoad?(reason)
    let container = UIView(frame: view.bounds)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .systemBackground

    let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    let label = UILabel()
    label.text = zh ? "网络不可用,请检查网络后重试" : "Network unavailable. Please check and retry."
    label.textColor = .secondaryLabel
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 0
    label.textAlignment = .center

    let button = UIButton(type: .system)
    button.setTitle(zh ? "重试" : "Retry", for: .normal)
    button.addTarget(self, action: #selector(load), for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
    ])
    view.addSubview(container)
    offlineView = container
  }
}

// MARK: - 导航回调

extension HecongChatViewController: WKNavigationDelegate {
  /// 🔴 **非 http(s) 导航必须由壳转交系统**(2026-08-18 owner 真机式实测抓出)。
  ///
  /// 病根:消息里的电话号码/邮箱,H5 是用 `window.location.href = "tel:…"` 触发的
  /// (`shared/text-entity-menu.tsx`、`appearance/action-dispatch.ts`)——**不走** `open-url`
  /// 桥通道,所以壳的 `setExternalUrlOpener` 那条链根本看不到它。
  /// 安卓能拨通是**另一条路碰巧接住了**(`shouldOverrideUrlLoading` 拦下非 http 交系统);
  /// iOS 没有对等实现 → WKWebView 对 `tel:` 导航**直接静默丢弃**,点"拨号"完全没反应
  /// (点"复制"却正常,因为复制不经导航)—— 两端行为不一致的根源。
  ///
  /// 修法:实现导航策略钩子,非 http(s)/本地骨架 scheme 一律 cancel 后交
  /// `openExternally`(带白名单 + 失败留痕)。与安卓 `shouldOverrideUrlLoading` 同语义。
  public func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction,
    decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
  ) {
    guard let url = navigationAction.request.url else { return decisionHandler(.allow) }
    let scheme = url.scheme?.lowercased() ?? ""
    // 骨架页自身 / 线上资源 / 页面内部导航照常放行
    if scheme == HecongBridgeConstants.localScheme || scheme == "http" || scheme == "https"
      || scheme == "about" || scheme == "data" || scheme == "blob" {
      return decisionHandler(.allow)
    }
    decisionHandler(.cancel)
    openExternally(url)
  }

  public func webView(
    _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
  ) {
    showOfflineView(reason: "provisional navigation failed: \(error.localizedDescription)")
  }

  public func webView(
    _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
  ) {
    showOfflineView(reason: "navigation failed: \(error.localizedDescription)")
  }

  public func webView(
    _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!
  ) {
    // 页面(重)加载 → 桥重建前回到排队态,期间命令积压等下一次 ready
    isBridgeReady = false
  }

  /// WebContent 进程被系统回收(内存吃紧时 iOS 会直接杀掉 WebView 的渲染进程)。
  ///
  /// 症状是**整页突然变全白**,且不触发任何导航失败回调 —— 不接这个方法的话
  /// WebView 就永远白着,用户以为客服挂了。标准做法是立刻重载(WKWebView 官方建议)。
  /// 同时上报:这类事故与宿主 APP 的内存占用强相关,租户那边只有我们的数据能看出来。
  public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    HecongErrorReporter.shared.report(
      scope: "load", message: "web content process terminated (likely OOM)",
      channelId: config.channelId)
    load()
  }
}

/// WKUserContentController 强持有 handler → 用 weak 代理断环(iOS WebView 经典泄漏点)
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
  private weak var target: HecongChatViewController?
  init(_ target: HecongChatViewController) { self.target = target }
  func userContentController(
    _ controller: WKUserContentController, didReceive message: WKScriptMessage
  ) {
    target?.handleNotification(message.body)
  }
}
