// 原生首屏圈的状态机(app-sdk-plan.md §11.4 转移表 T1–T18;协议 link-sdk-app-bridge.md §四.2)。
//
// 🔴 **纯 Swift,不 import UIKit / 不持有定时器 / 不读时钟** —— 这是它能被 XCTest 逐格钉住的前提
// (用例 S01–S25 在 HecongBootRingStateTests,与安卓 HecongBootRingStateTest 同名同序列)。
// 分工:VC 把事件喂进来(带单调时钟毫秒 `now`)→ 本类吐「指令列表」→ VC 把 `schedule` / `cancel`
// 变成真计时(到点再喂 `.timer(x)`)、把 `report` 交给 HecongErrorReporter、其余交给 HecongBootWaitView 照画。
//
// 改这张表 = 改规划:先改 §11.4,再改这里和两端用例(两端同一张表,逐条一致)。

import Foundation

struct HecongBootRingState {
  /// Idle 没有圈 · Pending 已挂、0.4s 等待期、透明 · Visible 淡入中或已显示 · Leaving 120ms 收尾中
  enum Phase: Equatable { case idle, pending, visible, leaving }

  /// 计时器。**声明顺序就是 cancelAll / poolResume 补排的输出顺序**(§11.4 通用规则,用例断言顺序)。
  enum Timer: CaseIterable, Equatable { case fadeIn, autoHide, report, exit }

  enum Event: Equatable {
    /// 主框架开始导航(didStartProvisionalNavigation)
    case navStart
    /// 桥 ready;`bootRing` = payload.capabilities 是数组且含 'boot-ring'
    case ready(bootRing: Bool)
    /// H5 通知 content-shown(首屏结束)
    case contentShown
    /// 骨架页观察脚本 notice-shown(整页提示,任何时候都收)
    case noticeShown
    /// loader-error / 导航失败 / 画兜底页
    case failed
    /// VC 销毁
    case destroy
    case poolSuspend
    case poolResume
    /// 宿主 App 进后台 / 回前台(didEnterBackground / willEnterForeground;重复喂幂等)
    case hostBackground
    case hostForeground
    case timer(Timer)
  }

  enum Command: Equatable {
    /// 挂上透明的圈、按 WebView 中心定位;未暂停则开始转
    case attach
    /// 220ms 线性淡入到 0.85
    case fadeIn
    /// 120ms 收尾(从当前呈现透明度开始)
    case fadeOut
    /// 立刻摘
    case remove
    case schedule(Timer, Int)
    case cancel(Timer)
    case report(String)
    case suspendVisual
    case resumeVisual
  }

  // ---- 计时(毫秒;与 H5 boot-ring-spec.ts 的 BOOT_RING_DELAY_MS / BOOT_RING_EXIT_MS 同值)----
  static let fadeInDelayMs = 400
  static let autoHideMs = 60000
  static let reportMs = 30000
  static let exitMs = 120

  static let reportMessage = "boot-ring: content-shown not received in 30s"

  private(set) var phase: Phase = .idle
  /// 本页 ready 带了 'boot-ring'
  private(set) var negotiated = false
  /// 在备用页池里
  private(set) var paused = false
  /// 宿主 App 在后台(与 `paused` 是两个独立的暂停原因,任一成立计时就停,两个都解除才续)
  private(set) var backgrounded = false
  private var suspended: Bool { paused || backgrounded }
  /// 当前已排上的计时 → 到期时刻(只在未暂停时有值)
  private var due: [Timer: Int] = [:]
  /// 暂停期的剩余毫秒(恢复时按它补排)
  private var remaining: [Timer: Int] = [:]

  /// 本次事件的时刻(handle 入口记下,schedule 按它算到期时刻)
  private var now = 0

  mutating func handle(_ event: Event, now: Int) -> [Command] {
    self.now = now
    // 迟到计时一律忽略;到点即撤(不再算已排上)
    if case .timer(let t) = event {
      guard due[t] != nil else { return [] }
      due[t] = nil
    }
    switch phase {
    case .idle: return idle(event)
    case .pending, .visible: return active(event)
    case .leaving: return leaving(event)
    }
  }

  // MARK: - 各状态

  private mutating func idle(_ event: Event) -> [Command] {
    switch event {
    case .navStart: return start() // T1
    case .poolSuspend: paused = true // T2:只改标志
    case .poolResume: paused = false
    case .hostBackground: backgrounded = true
    case .hostForeground: backgrounded = false
    default: break
    }
    return []
  }

  private mutating func active(_ event: Event) -> [Command] {
    switch event {
    case .navStart: // T3:不重挂、不重置 fadeIn / autoHide;新页面重新协商
      negotiated = false
      return cancel(.report)
    case .ready(bootRing: true):
      guard !negotiated else { return [] } // T5
      negotiated = true // T4
      return schedule(.report, Self.reportMs)
    case .timer(.fadeIn): // T7(只有 Pending 会排着 fadeIn)
      phase = .visible
      return [.fadeIn]
    case .timer(.report): // T8:只报一次,不收圈
      return [.report(Self.reportMessage)]
    // T12 / T13:池与后台是两个独立的暂停原因;只在「整体暂停」状态翻转时停表 / 续表
    case .poolSuspend:
      guard !paused else { return [] }
      let was = suspended
      paused = true
      return was ? [] : suspendTimers()
    case .poolResume:
      guard paused else { return [] }
      paused = false
      return suspended ? [] : resumeTimers()
    case .hostBackground:
      guard !backgrounded else { return [] }
      let was = suspended
      backgrounded = true
      return was ? [] : suspendTimers()
    case .hostForeground:
      guard backgrounded else { return [] }
      backgrounded = false
      return suspended ? [] : resumeTimers()
    case .failed, .destroy: // T6 / T11:兜底页与圈互斥,直接摘
      return finish(animated: false)
    case .ready(bootRing: false), .contentShown, .noticeShown, .timer(.autoHide):
      // Pending 屏上还透明 → 直接摘(T6);Visible 池里 / 后台没人看 → 直接摘(T10);否则淡出(T9)
      return finish(animated: phase == .visible && !suspended)
    case .timer(.exit):
      return [] // 非 Leaving 不会排 exit(handle 入口已挡住),防御
    }
  }

  private mutating func leaving(_ event: Event) -> [Command] {
    switch event {
    case .timer(.exit): // T14
      phase = .idle
      return [.remove]
    case .navStart: // T15
      return cancel(.exit) + [.remove] + start()
    case .failed, .destroy, .poolSuspend: // T16
      if event == .poolSuspend { paused = true }
      let out = cancel(.exit) + [.remove]
      phase = .idle
      return out
    case .hostBackground: // T18:120ms 收尾照走完,只记标志
      backgrounded = true
      return []
    case .hostForeground:
      backgrounded = false
      return []
    default: // T17:收尾中再来 contentShown / noticeShown 不重复淡出
      return []
    }
  }

  // MARK: - 动作

  /// T1:挂圈 + 两个计时(暂停中只记剩余)
  private mutating func start() -> [Command] {
    phase = .pending
    negotiated = false
    var out: [Command] = [.attach]
    out += schedule(.fadeIn, Self.fadeInDelayMs)
    out += schedule(.autoHide, Self.autoHideMs)
    if suspended { out.append(.suspendVisual) }
    return out
  }

  /// 每个已排上的计时 cancel 并记剩余;暂停转圈
  private mutating func suspendTimers() -> [Command] {
    var out: [Command] = []
    for t in Timer.allCases {
      guard let at = due.removeValue(forKey: t) else { continue }
      remaining[t] = max(0, at - now)
      out.append(.cancel(t))
    }
    out.append(.suspendVisual)
    return out
  }

  /// 每个剩余计时按剩余补排;恢复转圈
  private mutating func resumeTimers() -> [Command] {
    var out: [Command] = []
    for t in Timer.allCases {
      guard let ms = remaining.removeValue(forKey: t) else { continue }
      due[t] = now + ms
      out.append(.schedule(t, ms))
    }
    out.append(.resumeVisual)
    return out
  }

  /// cancelAll + 淡出进 Leaving(T9),或 cancelAll + 摘回 Idle(T6 / T10 / T11)
  private mutating func finish(animated: Bool) -> [Command] {
    var out = cancelAll()
    if animated {
      out.append(.fadeOut)
      out += schedule(.exit, Self.exitMs)
      phase = .leaving
    } else {
      out.append(.remove)
      phase = .idle
    }
    return out
  }

  /// 暂停期不起表:只记剩余
  private mutating func schedule(_ t: Timer, _ ms: Int) -> [Command] {
    if suspended {
      remaining[t] = ms
      return []
    }
    due[t] = now + ms
    return [.schedule(t, ms)]
  }

  /// 已排上 → 撤并输出;暂停中的剩余 → 直接清掉,不输出
  private mutating func cancel(_ t: Timer) -> [Command] {
    remaining[t] = nil
    guard due.removeValue(forKey: t) != nil else { return [] }
    return [.cancel(t)]
  }

  private mutating func cancelAll() -> [Command] {
    Timer.allCases.flatMap { cancel($0) }
  }
}
