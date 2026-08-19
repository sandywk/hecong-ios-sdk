// 无 UI 门面单例(app-sdk-plan.md §10.1 分层拨正)。
//
// 为什么要这一层:首版把 identify / 未读 / 上报全挂在聊天视图上 → **不打开聊天页,SDK 完全
// 是死的**(拿不到未读、没法提前 identify);且将来若做原生 UI,公共面必然破坏
// (workflow.md §10.4 公共 API 不可破坏)。对标 Intercom / Zendesk:全局单例管身份与未读,
// `present()` 管界面。
//
// 合规(§7.3 延迟初始化):本类**零活动**直到租户显式调用 —— configure 只登记参数,
// 不联网不读存储;未读跟踪要租户显式 startUnreadTracking 才启(§10.2 默认关闭)。
//
// 聊天视图**不依赖本门面**也能独立跑(与首版行为完全一致),不破坏既有接入方。

import Foundation
import UIKit

@objc(HecongChat)
public final class HecongChat: NSObject {
  @objc public static let shared = HecongChat()

  /// 未读 / 匿名号变化回调(与聊天视图共用同一份 delegate 协议,租户实现一个对象即可)。
  /// 门面只回调 `hecongChatUnreadDidChange` 与 `hecongChatDidChangeAnonymousId` 两项。
  @objc public weak var delegate: HecongChatDelegate?

  /// 当前已知未读数(未开启跟踪且没开过聊天页时恒 0)
  @objc public private(set) var unreadCount: Int = 0

  /// 最近一次的标题栏身份(宿主自绘标题栏用)。聊天页没开过时为 nil。
  /// 门面留一份是为了**页面重建后能立刻画对**(不用等下一次变化),同 unreadCount 的用意。
  @objc public private(set) var headerIdentity: HecongHeaderIdentity?

  private var config: HecongChatConfig?
  private var tracker: HecongUnreadTracker?
  private let cache = HecongRuntimeCache()

  /// 待重放身份(聊天页还没开时调 identify,页面起来后自动补发;详 HecongPendingIdentity)
  private let pendingIdentity = HecongPendingIdentity()

  /// 待重放壳状态(指派技能组 / 注册按钮;详 HecongPendingShellState)
  private let pendingShell = HecongPendingShellState()

  /// 已挂载的聊天视图。**弱引用表** —— 门面是单例、生命周期与 APP 同,强引用会把
  /// 关掉的聊天页永久留在内存里(经典单例泄漏)。视图可同时存在多个(见 setChatVisible)。
  private let targets = NSHashTable<AnyObject>.weakObjects()

  private override init() { super.init() }

  // MARK: - 配置登记(零活动)

  /// 登记配置。**只记参数,不联网、不读写存储** —— 可在 APP 启动时调,不违反延迟初始化要求。
  @objc public func configure(_ config: HecongChatConfig) {
    self.config = config
    HecongErrorReporter.shared.isEnabled = config.errorReportingEnabled
  }

  /// 一步登记:配置 + 回调一起给(等价于 configure 后再设 delegate)。
  @objc public func configure(_ config: HecongChatConfig, listener: HecongChatDelegate) {
    self.delegate = listener
    configure(config)
  }

  // MARK: - 未读跟踪(§10.2 opt-in,默认关闭)

  /// 开启未读跟踪。**必须租户显式调用**;三道闸门任一不过即零活动:
  /// ① 未 configure → 直接返回;② 本地无匿名号镜像(从没聊过天)→ 一个请求都不发;
  /// ③ 只在前台活动(内部自管,进后台立即停)。
  ///
  /// 重复调用幂等(已在跟踪则忽略)。
  /// 一步开启:登记回调 + 开启跟踪。等价于先设 `delegate` 再调无参的 `startUnreadTracking()`。
  ///
  /// 大多数接入只关心"有几条未读",所以给一个一步到位的入口;想分开写也行,老写法不变。
  @objc public func startUnreadTracking(listener: HecongChatDelegate) {
    self.delegate = listener
    startUnreadTracking()
  }

  @objc public func startUnreadTracking() {
    guard tracker == nil, let config = config else { return }
    // 闸门 ②:没聊过天的人不可能有未读 —— 零请求(§10.2)
    guard let anonymousId = HecongAnonymousIdStore(scope: config.anonymousIdScope).read(),
      !anonymousId.isEmpty
    else { return }
    // apiBase 由 H5 在 ready 时下发并缓存(§10.2:壳不另立一份配置,发版主炉是唯一事实源)。
    // 首次会话之前必然没有 → 与闸门 ② 同时成立,天然一致。
    guard let apiBase = cache.apiBase, !apiBase.isEmpty else { return }

    let tracker = HecongUnreadTracker(
      channelId: config.channelId, apiBase: apiBase, anonymousId: anonymousId,
      interval: config.unreadPollInterval
    ) { [weak self] count in
      self?.applyUnread(count)
    }
    self.tracker = tracker
    tracker.start()
  }

  /// 停止未读跟踪(退出登录 / 租户自己的开关关掉时调)。
  @objc public func stopUnreadTracking() {
    tracker?.stop()
    tracker = nil
  }

  // MARK: - 身份(§10.1:不打开聊天页也能绑定)

  /// 绑定已登录会员。**可在聊天页打开之前调**(如 APP 登录成功那一刻)——
  /// 身份会被记住,聊天页起来时自动补发,不需要租户自己挑时机。
  ///
  /// 已经开着聊天页时立即生效。多个聊天页同时开着时每个都会收到。
  @objc public func identify(
    userId: String, profile: [String: Any]? = nil, data: [String: Any]? = nil
  ) {
    guard !userId.isEmpty else { return }
    pendingIdentity.identify(userId: userId, profile: profile, data: data)
    forEachTarget { $0.identify(userId: userId, profile: profile, data: data) }
  }

  /// 更新会员资料(PATCH:没传的字段不动)。同样可在聊天页打开之前调。
  @objc public func updateUser(profile: [String: Any]? = nil, data: [String: Any]? = nil) {
    pendingIdentity.update(profile: profile, data: data)
    forEachTarget { $0.updateUser(profile: profile, data: data) }
  }

  /// 退出登录:清身份 + 结束当前对话。**APP 登出时必须调** ——
  /// 不调的话下一个在同一台设备上登录的人会看到上一个人的聊天记录。
  @objc public func resetUser() {
    pendingIdentity.reset()
    forEachTarget { $0.resetUser() }
  }

  // MARK: - 会话指派(app-sdk-plan.md §10.7 / sdk-agent-routing.md)

  /// 指定本次咨询由哪个**技能组**接待。可在打开聊天页之前调(自动重放)。
  ///
  /// 传 nil 清除。要细配降级策略用 `setRouting(_ routing:)` 那个重载。
  /// ⚠️ **只在"聊天页开着时要换组"或"启动前动态决定"才用它** —— 值固定的场景直接配
  /// `HecongChatConfig.routing` 更省事(走 URL 档,连桥都不用等)。
  @objc public func setRouting(_ skillGroup: String?) {
    guard let skillGroup = skillGroup, !skillGroup.isEmpty else {
      setRouting(nil as HecongRouting?)
      return
    }
    setRouting(HecongRouting(skillGroup: skillGroup))
  }

  /// 同上,带降级策略(`fallback` = "group" / "normal" / "leave_message")。
  /// ObjC 侧选择器显式改名 `setRoutingOptions:` —— 与上面的字符串重载**同名会撞选择器**
  /// (ObjC 不认识 Swift 的重载,两者都会映射成 `setRouting:`,编译期直接报错)。
  @objc(setRoutingOptions:) public func setRouting(_ routing: HecongRouting?) {
    pendingShell.setRouting(routing)
    // payload 里的 `routing` 显式给 NSNull 转成的 nil —— H5 侧 `{ routing: null }` 即清除语义
    let payload: [String: Any] = ["routing": routing?.payload() as Any? ?? NSNull()]
    forEachTarget { $0.sendCommand("setRouting", payload: payload) }
  }

  // MARK: - 选择器与自定义按钮(契约 §九;商品/订单/文章卡片的入口)

  /// 往输入区加一个自定义按钮。点击 → `hecongChat(didClickAction:)` 回调。
  ///
  /// - Parameters:
  ///   - slot: `"attach"` 附件面板(📎 里,收着)/ `"quick"` 快捷按钮区(输入框正上方,显眼)
  ///   - icon: 可选内联 SVG 串(`<svg` 开头);不给用通用图标
  ///
  /// 同 id 重复注册 = 覆盖。可在打开聊天页之前调(自动重放,页面重建后按钮仍在)。
  @objc public func registerAction(id: String, label: String, icon: String?, slot: String) {
    guard !id.isEmpty, !label.isEmpty else { return }
    var payload: [String: Any] = ["id": id, "label": label, "slot": slot]
    if let icon = icon, !icon.isEmpty { payload["icon"] = icon }
    pendingShell.registerAction(payload)
    forEachTarget { $0.sendCommand("registerAction", payload: payload) }
  }

  /// 撤掉自定义按钮(id 不存在 = 无副作用)。
  @objc public func unregisterAction(_ id: String) {
    pendingShell.unregisterAction(id)
    forEachTarget { $0.sendCommand("unregisterAction", payload: ["id": id]) }
  }

  /// 供给选择器数据。`picker` = "product" / "order" / "article";`items` 是卡片字典数组
  /// (字段见 `packages/models/src/message/card.ts`,如商品:`cardType`/`title`/`imageUrl`/`price`)。
  ///
  /// ⚠️ **在 `didClickAction` 回调里现取现给**,别在启动时灌一次了事 —— 商品/订单列表
  /// 随登录态与库存变化,陈旧列表发出去的是错卡片。上限 50 条(超出 H5 侧自动截断)。
  /// 聊天页没开时调 = 无效(**刻意不重放**,理由见 HecongPendingShellState 头注释)。
  @objc public func setPickerData(_ picker: String, items: [[String: Any]]) {
    forEachTarget { $0.sendCommand("setPickerData", payload: ["picker": picker, "items": items]) }
  }

  /// 打开选择器面板(通常紧跟 `setPickerData` 调用)。聊天页没开时无效。
  @objc public func openPicker(_ picker: String) {
    forEachTarget { $0.sendCommand("openPicker", payload: ["picker": picker]) }
  }

  /// **通用命令透传口**(桥协议 §三.2)—— 逃生梯,不是首选。
  ///
  /// 上面那些具名方法是承诺(有类型、有文档);本方法用于**壳版本还没跟上的新命令** ——
  /// H5 侧新增命令后,不必等我们发原生包、也不必等你升级 SDK,自己拼 type + payload 就能调。
  /// H5 不认识的 type 会被安全丢弃(返回 unknown_command 并留痕),不会崩。
  @objc public func sendCommand(_ type: String, payload: [String: Any]?) {
    guard !type.isEmpty else { return }
    forEachTarget { $0.sendCommand(type, payload: payload) }
  }

  // MARK: - 聊天视图协作(internal,视图起来时交接)

  /// 聊天视图挂载 → 登记 + **重放已登记的身份**(命令进视图自己的队列,桥 ready 后发出)。
  ///
  /// 时机是 attach 而不是 ready:视图自带 ready 前排队,这里不必再等一层
  /// (两级队列各司其职,详 HecongPendingIdentity 头注释)。
  func attachTarget(_ target: HecongChatCommandTarget) {
    targets.add(target)
    // 壳状态(指派组 / 注册按钮)与身份**都要重放**,且互不依赖 —— 身份可能没有(匿名访客),
    // 那时按钮和指派组照样要生效,所以壳状态重放不能挂在身份的 guard 后面
    pendingShell.replay(into: target)
    guard let userId = pendingIdentity.userId else { return }
    target.identify(
      userId: userId,
      profile: pendingIdentity.profile.isEmpty ? nil : pendingIdentity.profile,
      data: pendingIdentity.data.isEmpty ? nil : pendingIdentity.data)
  }

  /// 聊天视图卸载 → 摘登记(弱表本身也会自动清,显式摘是为了立刻停止转发)
  func detachTarget(_ target: HecongChatCommandTarget) {
    targets.remove(target)
  }

  private func forEachTarget(_ block: (HecongChatCommandTarget) -> Void) {
    for case let t as HecongChatCommandTarget in targets.allObjects { block(t) }
  }


  /// 视图 ready 时把 H5 下发的 apiBase 缓存下来,供**下次启动**的未读跟踪用
  func cacheApiBase(_ apiBase: String) {
    cache.apiBase = apiBase
  }

  /// 当前可见的聊天视图数(**引用计数,不是布尔**,原因见 setChatVisible)
  private var visibleChats = 0

  /// 聊天页开着时暂停轮询 —— 那时 WS 是权威来源,未读由 H5 的 unread 通知直接喂进来。
  ///
  /// 🔴 **必须计数不能用布尔**(2026-08-18 专项排查抓出):聊天视图可以**同时存在多个**
  /// (push 一个再 present 另一个;或租户把聊天常驻某 Tab 又另弹一个)。布尔写法下,
  /// 关掉其中任意一个就会把"暂停"整个解除 —— 另一个还开着,于是**轮询与 WS 两个未读源
  /// 同时在写**,未读数会来回跳(正是本设计要避免的"两个源打架")。
  /// 计数归零才真正恢复;负数 clamp(VC 重建等边界下 disappear 可能多于 appear)。
  func setChatVisible(_ visible: Bool) {
    visibleChats = visible ? visibleChats + 1 : max(0, visibleChats - 1)
    tracker?.setPaused(visibleChats > 0)
  }

  /// H5 侧未读通知(聊天页开着时的权威来源)
  func applyUnread(_ count: Int) {
    guard unreadCount != count else { return }
    unreadCount = count
    delegate?.hecongChatUnreadDidChange?(count)
  }

  /// 标题栏身份变化(聊天视图收到桥通知后喂进来)
  func applyHeaderIdentity(_ identity: HecongHeaderIdentity) {
    headerIdentity = identity
    delegate?.hecongChatHeaderIdentityDidChange?(identity)
  }

  /// 生效匿名号变化 → 透给宿主(推送闭环:租户据此建 anonymousId ↔ pushToken 映射,§10.5)
  func notifyAnonymousIdChanged(_ anonymousId: String) {
    delegate?.hecongChatDidChangeAnonymousId?(anonymousId)
  }
}

/// 壳运行时缓存(非身份数据,UserDefaults 足够)。apiBase 的唯一事实源是发版主炉,
/// 这里只是 H5 下发值的本地副本(§10.2)。
final class HecongRuntimeCache {
  private let key = "hecong.chat.apiBase"

  var apiBase: String? {
    get { UserDefaults.standard.string(forKey: key) }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }
}
