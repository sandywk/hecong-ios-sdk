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
    // 记下"租户要未读"这个意愿 —— 登出会暂停跟踪,拿到新号后据此自动恢复(见 settleIdentityResetOnReady)
    cache.unreadTrackingWanted = true
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

  /// 停止未读跟踪(租户自己的开关关掉时调)。
  ///
  /// ⚠️ 与登出内部那次暂停不同:**这里是租户明确表示不要了**,所以连意愿一起清掉,
  /// 不会被后续的"拿到新号自动恢复"复活。
  @objc public func stopUnreadTracking() {
    cache.unreadTrackingWanted = false
    suspendUnreadTracking()
  }

  /// 内部暂停(登出用):停轮询但**保留意愿**,拿到新号后自动恢复。
  private func suspendUnreadTracking() {
    tracker?.stop()
    tracker = nil
  }

  // MARK: - 身份(§10.1:不打开聊天页也能绑定)

  /// 绑定已登录会员 + 写资料。**传什么覆盖什么**(PATCH:传了的字段覆盖,没传的不动),
  /// **任何时机可调**:登录时、资料变了(APP 版本号一类)、换了会员,都调它,它是唯一的资料写入口
  /// (2026-09-05 起 `updateUser` 已删,不留兼容)。
  ///
  /// **可在聊天页打开之前调**(如 APP 登录成功那一刻)—— 身份会被记住(同一个人多次调用逐字段
  /// 合并),聊天页起来时自动补发一次,不需要租户自己挑时机。已经开着聊天页时立即生效。
  /// - Parameters:
  ///   - profile: 系统内置四字段(姓名/头像/手机/邮箱)——**类型化,写错键名编译不过**
  ///   - data: 租户在工作台「自定义字段」里自建的业务字段;**未定义的 key 会被后端丢弃**,
  ///     丢了哪些经 ``HecongChatDelegate/hecongChatDidIgnoreCustomFields(_:)`` 回执
  @objc public func identify(
    userId: String, profile: HecongProfile? = nil, data: [String: Any]? = nil
  ) {
    guard !userId.isEmpty else { return }
    let dict = profile?.toDictionaryOrNil()
    pendingIdentity.identify(userId: userId, profile: dict, data: data)
    forEachTarget { $0.identifyRaw(userId: userId, profile: dict, data: data) }
  }

  /// 退出登录:清身份 + 结束当前对话。**APP 登出时必须调** ——
  /// 不调的话下一个在同一台设备上登录的人会看到上一个人的聊天记录。
  ///
  /// **聊天页开着与否都生效**(2026-08-21,桥协议 §二.4)。租户在自己的设置页点退出时
  /// 聊天页通常是关着的 —— 那一刻没有任何命令接收方,所以本方法**同时**做两件事:
  ///   1. 开着 → 直接下发 `userReset`,H5 走完整链路(后端也会关掉旧对话)
  ///   2. 无论开没开 → 记一笔待兑现,下次页面装载时经启动 context 转达给 H5
  ///
  /// 两条路重合时不会重复换号:H5 那边的判据是"本设备绑过会员没有",第 1 条走完之后
  /// 绑定记录已清,第 2 条到达时会被自动忽略(幂等)。
  ///
  /// **壳这边不碰号、不删存储、也不发任何后端请求** —— 号的真源在 H5,壳只做镜像与传话
  /// (`HecongAnonymousIdStore` 头注释)。壳自己动手会跟 H5 打架,而且后端那边反而更脏。
  @objc public func resetUser() {
    pendingIdentity.reset()
    // 待兑现标记**无条件置位**,壳不做任何身份判断:
    // "这台设备绑过会员没有"那份事实只有 H5 的本地存储知道,壳读不到也不该读一份副本
    // (两份记同一件事、写入时机还不同 → 必然漂移)。纯匿名时 H5 会自动忽略。
    cache.pendingIdentityReset = true
    // 🔴 换人 → 备用页立刻作废。池子里那个装着**上一个人的会话**,留着就是把他的聊天记录
    // 端给下一个人(§10.3.1 同款血泪:换人不换号)。判据刻意粗,理由见 dropForIdentityChange。
    HecongChatPool.shared.dropForIdentityChange()
    // 暂停未读:此刻壳手里还是旧号,继续轮询就是替**上一个人**拉未读数。
    // 意愿保留,拿到新号后自动恢复(见 settleIdentityResetOnReady)。
    suspendUnreadTracking()
    applyUnread(0)
    forEachTarget { $0.resetUser() }
  }

  // MARK: - 备用聊天页(预热 / 保活,HecongChatPool)

  /// 门面当前登记的会员 ID(nil = 匿名)。备用页签名要用它判"是不是同一个人"。
  /// **这是壳自己发出去过的值**,不是去读 H5 里那份真源(读副本必然漂移,见 resetUser 注释)。
  var currentUserId: String? { pendingIdentity.userId }

  /// 提前把聊天页准备好,用户点开时**秒开**。
  ///
  /// ## 🔴 什么时候调 —— 必须在「用户已同意隐私政策」之后
  ///
  /// 本方法**会联网、会写本地存储**(它就是真的把整条链跑一遍)。
  /// 国内应用商店(华为/小米尤严)审核的第一杀手就是「用户同意隐私政策前第三方 SDK 就联网」,
  /// 出事是**租户被拒审/下架**。所以它刻意**没有**塞进 `configure()` ——
  /// 那个方法被设计成零活动、允许在 App 启动时就调(见其注释),两者语义完全不同,别合并。
  /// 同款先例:`startUnreadTracking()` 也是"显式 opt-in + 闸门",不是自动开。
  ///
  /// ## 不调也不亏
  ///
  /// **保活是默认开的、全自动的** —— 用户用过一次聊天页之后,退出时会自动留作备用页,
  /// 5 分钟内再进就是秒开。本方法只是把这份收益**提前到第一次打开**。
  /// 租户一行不写也能拿到"第二次进很快",调了才多拿"第一次也很快"。
  ///
  /// ## 安全性
  ///
  /// 预热出来的 WebView **不挂进任何视图树**,结构上不可能在租户界面里露脸(实测见
  /// `HecongChatPool` 头注释)。换人/换渠道/内存告警/渲染进程被杀/超时五道闸门全自动生效,
  /// **租户不需要记得调用任何清理方法**。
  ///
  /// 重复调用幂等(已有备用页则忽略)。
  @objc public func prewarm() {
    guard let config = config else { return } // 没 configure 过 → 零活动
    HecongChatPool.shared.prewarm(config: config)
  }

  // MARK: - 会话指派(app-sdk-plan.md §10.7 / sdk-agent-routing.md)

  /// 指定本次咨询由哪个**技能组**接待。可在打开聊天页之前调(自动重放)。
  ///
  /// 传 nil 清除。要细配降级策略用 `setRouting(_ routing:)` 那个重载。
  /// ⚠️ **只在"聊天页开着时要换组"或"启动前动态决定"才用它** —— 值固定的场景直接配
  /// `HecongChatConfig.routing` 更省事(走 URL 档,连桥都不用等)。
  // MARK: - 打开聊天页(承载形态,app-sdk-chat-entry.md §二;与安卓 start/startImmersive 逐条对位)
  //
  // 🔴 **三档都不要租户传 presenter**(2026-09-05 owner 定,零包袱一步到位):SDK 经
  // `HecongPresenterResolver` 自己找前台最上层控制器。理由:SwiftUI 工程按钮回调里没有 self,
  // 租户得自己写十几行"找顶层控制器";安卓传 context 哪都有,两端本就不对等;Intercom / Zendesk 的
  // `present()` 一律不要 presenter。想精确控制从哪弹的,走第③档自己拿 `HecongChatViewController` 摆放。
  // 返回 nil 只有一种情况:前台没有任何窗口(APP 还没起窗口就调 / 纯后台),此时什么都不做、不 crash。
  // ObjC 名字显式给(app-sdk-chat-entry.md §七之二 互操作坑 4)。

  /// **标准档**(绝大多数租户用这个):推进你当前页面所在的导航栏里 —— 顶栏就是你家那条,
  /// 字体/返回箭头/配色/暗色全自动跟你的 APP 一致,SDK 一个像素都不画。
  ///
  /// **没有导航栈**(纯 modal 层 / SwiftUI 无 NavigationStack)→ 退化成全屏弹页,
  /// 顶上包一条系统导航栏 + 右上 ✕(标题与配色项照旧生效),功能一样不缺。
  ///
  /// 安卓对位:`HecongChatActivity.start(context, config)`。
  ///
  /// 标题:`config.title` 有值就填;没传则「在线客服」。
  ///
  /// ```swift
  /// HecongChat.shared.push(config: HecongChatConfig(channelId: "渠道ID"))
  /// ```
  @discardableResult
  @objc(pushWithConfig:)
  public func push(config: HecongChatConfig) -> HecongChatViewController? {
    guard let top = HecongPresenterResolver.topViewController() else { return nil }
    if let nav = (top as? UINavigationController) ?? top.navigationController {
      return pushInto(nav, config: config)
    }
    let vc = HecongChatViewController(config: config)
    if vc.title == nil || vc.title?.isEmpty == true { vc.title = config.resolveTitle() }
    let nav = UINavigationController(rootViewController: vc)
    vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: vc, action: #selector(HecongChatViewController.closeFromChrome))
    if #available(iOS 11.0, *) { vc.navigationItem.largeTitleDisplayMode = .never }
    applySheetChrome(nav: nav, config: config)
    nav.modalPresentationStyle = .fullScreen
    top.present(nav, animated: true)
    return vc
  }

  /// 标准档实现:推进指定导航栈。
  private func pushInto(_ navigationController: UINavigationController, config: HecongChatConfig)
    -> HecongChatViewController
  {
    // 备用页命中 = 秒开(整条链不用重跑);拿不到就照旧新建。
    // 只有**标准档**走池子:弹层/沉浸档各自带着呈现态(detent、导航栏接管),复用要多守一堆
    // 状态,收益却一样 —— 先只做最常用这一档,稳了再说(§0 稳定第一)。
    let vc = HecongChatPool.shared.take(config: config) ?? HecongChatViewController(config: config)
    // 复用时把纯壳侧 UI 项覆盖一遍(它们不进池子签名,见 HecongChatPool.signature)
    if vc.title == nil || vc.title?.isEmpty == true { vc.title = config.resolveTitle() }
    // 聊天是沉浸页:推入时收起宿主的底部 Tab。**设在这里而不是交给调用方** ——
    // 靠调用方各自记得设,漏一处就是"聊天页底下压着一条 Tab 栏"(2026-08-19 真机实测到)
    vc.hidesBottomBarWhenPushed = true
    // 标题压成**一行紧凑**,不吃 iOS 大标题(2026-08-20 owner 实拍反馈"顶栏怎么这么高")。
    // 理由:①聊天页几乎没有"大标题"诉求,那是列表页的语言;②大标题会随滚动收缩,而下面是
    // WebView 自己的滚动,两套滚动不同步,收缩动画会一顿一顿。
    // 租户想要大标题:push 之后自行 `vc.navigationItem.largeTitleDisplayMode = .always`。
    if #available(iOS 11.0, *) { vc.navigationItem.largeTitleDisplayMode = .never }
    navigationController.pushViewController(vc, animated: true)
    return vc
  }

  /// **弹层档**:底部半屏卡片承载(默认 0.82 屏,`config.sheetHeightRatio` 可配),
  /// 适合"聊一句就走、不离开当前页"的场景。**没有返回栈,✕ 是唯一出口**。
  ///
  /// 安卓对位:`HecongChatActivity.startSheet(context, config)`。
  ///
  /// 🔴 **手势优先级**:`prefersScrollingExpandsWhenScrolledToEdge = false` —— 让**聊天列表
  /// 优先吃滚动手势**。不设的话系统规矩是「滚到顶再下拉 = 收起弹层」,而我们列表滚到顶的语义是
  /// 「再往上翻更早的消息」,同一个手势两种语义会撞车(租户想翻记录,弹层被拉走)。
  /// 拖拽交给抓手条/标题区,与安卓侧同一条原则(各用各的系统开关)。
  ///
  /// **降级(`.claude/rules/sdk-specific.md §0.5` 能用最新就用最新,老系统降级)**:
  /// iOS 16+ 自定义比例;iOS 15 退系统半屏;**iOS 13/14 没有系统弹层 → 整档退成全屏 modal**
  /// (✕ 仍在,功能不缺,只是形态退化)。
  ///
  /// ```swift
  /// HecongChat.shared.presentSheet(config: config)
  /// ```
  @discardableResult
  @objc(presentSheetWithConfig:)
  public func presentSheet(config: HecongChatConfig) -> HecongChatViewController? {
    return presentSheet(config: config, useChannelHeader: false)
  }

  /// 弹层档 · 顶栏两选一(2026-08-20 owner 提)。
  ///
  /// - `useChannelHeader = false`(默认):**系统导航栏** —— 标题 + 系统关闭件,跟你 App 里
  ///   其它弹层一个模子;配色可经 config 覆盖,还要更自由就拿返回的 vc 改 `navigationItem`。
  /// - `useChannelHeader = true`:**卡片里整页交给聊天页** —— 顶上是渠道后台配的那条彩色标题栏
  ///   (品牌感更强),右侧 ✕ 由它画,点了收起弹层。
  ///
  /// 本质上后者 = 「沉浸档装进弹层」,所以内部直接复用沉浸档那套(不新造形态,详实现)。
  @discardableResult
  @objc(presentSheetWithConfig:useChannelHeader:)
  public func presentSheet(config: HecongChatConfig, useChannelHeader: Bool)
    -> HecongChatViewController?
  {
    guard let top = HecongPresenterResolver.topViewController() else { return nil }
    return presentSheet(on: top, config: config, useChannelHeader: useChannelHeader)
  }

  /// 弹层档实现:从指定控制器弹出。
  private func presentSheet(
    on presenter: UIViewController, config: HecongChatConfig, useChannelHeader: Bool
  ) -> HecongChatViewController {
    let vc = HecongChatViewController(config: config)
    vc.sheetMode = true
    if useChannelHeader {
      // 复用沉浸档语义:hh=0(H5 画自己那条)+ 壳不画顶栏 + ✕ 经 close capability 通知壳收起。
      // 三件事一个标记全带上,不必再造一套并行分支。
      vc.immersive = true
      applySheetDetents(on: vc, config: config)
      presenter.present(vc, animated: true)
      return vc
    }
    // 🔴 **弹层顶条用系统导航栏,不自绘**(2026-08-20 owner 走查"手画的那条很粗糙")。
    // iOS 对"弹层 + 标题 + 关闭"早有标准答案:内容包一层 UINavigationController,
    // 标题走 `title`、关闭走系统 `.close` bar button(iOS 13+ 那个标准圆底 ✕)。
    // 白捡的一堆细节:字号字重/左右间距/暗色适配/滚动时的边缘外观/安全区,全是系统给的,
    // 而且**跟租户自家 App 里其它弹层长得一模一样** —— 自绘再精细也做不到这点。
    let nav = UINavigationController(rootViewController: vc)
    vc.navigationItem.rightBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close, target: vc, action: #selector(HecongChatViewController.closeFromChrome))
    if #available(iOS 11.0, *) { vc.navigationItem.largeTitleDisplayMode = .never }
    // 配色项在这一档同样生效 —— 否则"改了 config 却没反应"(2026-08-20 owner 追问:
    // "租户喜欢这个弹层但想改标题栏怎么办")。三级台阶与标准档一致:
    //   零配置 = 系统样式 → config 配色 = 这里 → 还要更自由 = 拿返回的 vc 改 navigationItem
    //   (titleView / 左右按钮 / tintColor 全在你手里,那是标准 UIKit,我们不拦)。
    applySheetChrome(nav: nav, config: config)
    applySheetDetents(on: nav, config: config)
    presenter.present(nav, animated: true)
    return vc
  }

  /// 弹层的高度档位与手势规则(两种顶栏形态共用)。
  private func applySheetDetents(on presented: UIViewController, config: HecongChatConfig) {
    guard #available(iOS 15.0, *), let sheet = presented.sheetPresentationController else {
      presented.modalPresentationStyle = .fullScreen // iOS 13/14:无系统弹层,退全屏
      return
    }
    sheet.prefersGrabberVisible = true
    sheet.prefersScrollingExpandsWhenScrolledToEdge = false // 见上:聊天列表优先吃滚动
    let ratio = max(0.3, min(1.0, config.sheetHeightRatio))
    if #available(iOS 16.0, *) {
      // 自定义比例 + 全屏两档 = "上拉全屏、下拉关闭"
      let custom = UISheetPresentationController.Detent.custom { context in
        context.maximumDetentValue * ratio
      }
      sheet.detents = [custom, .large()]
    } else {
      // iOS 15:只有系统写死的两档,比例配置在这一档失效(行为不坏)
      sheet.detents = [.medium(), .large()]
    }
  }

  /// 把 config 的标题栏配色应用到系统导航栏(弹层档)。
  /// 不配则保持系统外观 —— **不配 ≠ 画成白色**,系统外观自带暗色适配与毛玻璃。
  private func applySheetChrome(nav: UINavigationController, config: HecongChatConfig) {
    guard config.headerBackgroundColor != nil || config.titleColor != nil else { return }
    if #available(iOS 13.0, *) {
      let appearance = UINavigationBarAppearance()
      appearance.configureWithDefaultBackground()
      if let bg = config.headerBackgroundColor {
        appearance.configureWithOpaqueBackground() // 配了底色就别再叠毛玻璃,否则颜色不准
        appearance.backgroundColor = bg
      }
      if let fg = config.titleColor {
        appearance.titleTextAttributes = [.foregroundColor: fg]
        nav.navigationBar.tintColor = fg // 关闭件跟着走,不然底色深了 ✕ 看不见
      }
      nav.navigationBar.standardAppearance = appearance
      nav.navigationBar.scrollEdgeAppearance = appearance
    } else {
      config.headerBackgroundColor.map { nav.navigationBar.barTintColor = $0 }
      config.titleColor.map { nav.navigationBar.tintColor = $0 }
    }
  }

  /// **沉浸档**:整页交给 H5(渠道后台配的那条彩色标题栏 + 右上 ✕ 退出),适合想要整页品牌感的租户。
  ///
  /// **呈现方式(2026-08-22 重订)**:当前页面在导航栈里 → **push**(隐藏系统导航栏、H5 画顶栏,
  /// **系统侧滑返回保留**,✕ 仍在);没有导航栈 → 退回全屏 modal(✕ 是唯一出口)。
  /// 为什么不再一律 modal:全屏 modal 在 iOS 上**没有任何退出手势**,客户进来后只能找右上角那个 ✕
  /// —— owner iPhone 真机走查"退出来麻烦,租户会投诉"。安卓这一档是普通 Activity,系统返回手势
  /// 天然可用;iOS 改 push 正好对齐(两端都是「H5 ✕ + 系统手势」两个出口)。
  ///
  /// 安卓对位:`HecongChatActivity.startImmersive(context, config)`。
  ///
  /// 📌 iOS 这一档天然完整:WebView 铺满到屏幕顶,H5 标题栏自己吃安全区,
  /// **状态栏底色跟着 H5 顶栏走**,零配置(安卓侧要等刀 7 的 insets 专项才有,详 §5.1.1)。
  ///
  /// ```swift
  /// HecongChat.shared.presentImmersive(config: config)
  /// ```
  @discardableResult
  @objc(presentImmersiveWithConfig:)
  public func presentImmersive(config: HecongChatConfig) -> HecongChatViewController? {
    guard let top = HecongPresenterResolver.topViewController() else { return nil }
    return presentImmersive(on: top, config: config)
  }

  /// 沉浸档实现:从指定控制器进入。
  private func presentImmersive(on presenter: UIViewController, config: HecongChatConfig)
    -> HecongChatViewController
  {
    let vc = HecongChatViewController(config: config)
    vc.immersive = true
    if let nav = (presenter as? UINavigationController) ?? presenter.navigationController {
      // 与 pushInto 同一套纪律:收起底部 Tab、不吃大标题(大标题在隐藏导航栏下也无意义)
      vc.hidesBottomBarWhenPushed = true
      if #available(iOS 11.0, *) { vc.navigationItem.largeTitleDisplayMode = .never }
      vc.pushedImmersive = true // 让 VC 自己接管"隐藏导航栏 + 保活侧滑 + 离场还原"
      nav.pushViewController(vc, animated: true)
      return vc
    }
    vc.modalPresentationStyle = .fullScreen // 沉浸 = 整页,不要卡片式半盖
    presenter.present(vc, animated: true)
    return vc
  }

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
    // 聊天页没开 = 命令没有接收方 → **丢弃,但留痕**。
    //
    // 刻意**不缓冲**:壳不知道这条命令是什么语义,猜着缓冲可能更糟 —— 比如"打开选择器"
    // 被攒住,半小时后页面一开突然弹出来,那是 bug 不是特性。将来真有需要跨页面存活的
    // 新命令,那时把它提升成具名方法(具名方法才有资格决定自己的重放语义,如
    // identify 的合并容器 / registerAction 的全量表)。
    //
    // 有留痕才排查得动:此前是**静默丢弃**,租户只会看到"我调了怎么没反应"。
    guard !type.isEmpty else { return }
    if !hasLiveTarget {
      HecongErrorReporter.shared.report(
        scope: "bridge", message: "command '\(type)' dropped: no chat view mounted",
        channelId: config?.channelId)
      return
    }
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
    // 重放一条合并后的 identify(同一个人多次调用已逐字段合并,详 HecongPendingIdentity 头注释)
    target.identifyRaw(
      userId: userId,
      profile: pendingIdentity.profile.isEmpty ? nil : pendingIdentity.profile,
      data: pendingIdentity.data.isEmpty ? nil : pendingIdentity.data)
  }

  /// 聊天视图卸载 → 摘登记(弱表本身也会自动清,显式摘是为了立刻停止转发)
  func detachTarget(_ target: HecongChatCommandTarget) {
    targets.remove(target)
  }

  /// 当前有没有活着的聊天视图(命令有没有接收方)
  private var hasLiveTarget: Bool {
    targets.allObjects.contains { $0 is HecongChatCommandTarget }
  }

  private func forEachTarget(_ block: (HecongChatCommandTarget) -> Void) {
    for case let t as HecongChatCommandTarget in targets.allObjects { block(t) }
  }


  /// 视图装载时要不要转达"宿主已登出"(桥协议 §二.4)。
  ///
  /// 壳只传话:纯匿名时 H5 会自己忽略(判据"绑过会员没有"那份事实只有它的本地存储知道)。
  var pendingIdentityReset: Bool { cache.pendingIdentityReset }

  /// 桥 ready → 结算待兑现的登出重置。
  ///
  /// **必须等 ready,不能注入时就划掉** —— 页面可能压根没起来(断网 / 静态域不可达),
  /// 那时划掉等于把这次登出永久丢了。ready 到了才说明 H5 真的读到了那个启动参数。
  ///
  /// 顺带恢复未读:登出时暂停了轮询(那时手里还是旧号),此刻 H5 已回报新号、镜像也更新过,
  /// 用新号接着跟踪才是对的。租户显式 stop 过则不恢复(那是"不要了",意愿已清)。
  func settleIdentityResetOnReady() {
    if cache.pendingIdentityReset { cache.pendingIdentityReset = false }
    if cache.unreadTrackingWanted && tracker == nil { startUnreadTracking() }
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
    // delegate 协议是 @MainActor;门面本身没标(ObjC / Swift 5 老工程零负担),调用点已在主线程
    // (未读轮询回调已 hop 回主线程、桥消息在主线程),这里只是把这个事实告诉编译器
    MainActor.assumeIsolated { delegate?.hecongChatUnreadDidChange?(count) }
  }

  /// 标题栏身份变化(聊天视图收到桥通知后喂进来)
  func applyHeaderIdentity(_ identity: HecongHeaderIdentity) {
    headerIdentity = identity
    MainActor.assumeIsolated { delegate?.hecongChatHeaderIdentityDidChange?(identity) }
  }

  /// 生效匿名号变化 → 透给宿主(推送闭环:租户据此建 anonymousId ↔ pushToken 映射,§10.5)
  func notifyAnonymousIdChanged(_ anonymousId: String) {
    MainActor.assumeIsolated { delegate?.hecongChatDidChangeAnonymousId?(anonymousId) }
  }
}

/// 壳运行时缓存(非身份数据,UserDefaults 足够)。apiBase 的唯一事实源是发版主炉,
/// 这里只是 H5 下发值的本地副本(§10.2)。
final class HecongRuntimeCache {
  private let key = "hecong.chat.apiBase"
  private let resetKey = "hecong.chat.pendingIdentityReset"
  private let unreadWishKey = "hecong.chat.unreadTrackingWanted"

  var apiBase: String? {
    get { UserDefaults.standard.string(forKey: key) }
    set { UserDefaults.standard.set(newValue, forKey: key) }
  }

  /// 待兑现的登出重置(桥协议 §二.4)。
  ///
  /// **必须落盘,不能只放内存** —— 租户点完退出登录,他自己的登录态就清了;APP 被杀掉之后
  /// 他**不会再调一次**(没什么可退的了)。这一笔丢了就是永远丢了,而它防的正是
  /// 「下一个人在这台设备上看到上一个人的记录」。反过来 identify 不需要落盘:租户的登录态
  /// 本身是持久的,APP 重启恢复登录态时会再告诉我们一遍。
  ///
  /// 只是个布尔,不含会员 ID / 资料,不碰隐私清单(§10.3)。
  var pendingIdentityReset: Bool {
    get { UserDefaults.standard.bool(forKey: resetKey) }
    set { UserDefaults.standard.set(newValue, forKey: resetKey) }
  }

  /// 租户是否开过未读跟踪(登出会暂停它,拿到新号后据此自动恢复)。
  /// 不记的话租户得自己记着重新开一次 —— 他不会知道,未读就静默没了。
  var unreadTrackingWanted: Bool {
    get { UserDefaults.standard.bool(forKey: unreadWishKey) }
    set { UserDefaults.standard.set(newValue, forKey: unreadWishKey) }
  }
}
