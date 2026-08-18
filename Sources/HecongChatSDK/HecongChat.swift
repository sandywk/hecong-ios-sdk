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

  // MARK: - 聊天视图协作(internal,视图起来时交接)

  /// 聊天视图挂载 → 登记 + **重放已登记的身份**(命令进视图自己的队列,桥 ready 后发出)。
  ///
  /// 时机是 attach 而不是 ready:视图自带 ready 前排队,这里不必再等一层
  /// (两级队列各司其职,详 HecongPendingIdentity 头注释)。
  func attachTarget(_ target: HecongChatCommandTarget) {
    targets.add(target)
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
