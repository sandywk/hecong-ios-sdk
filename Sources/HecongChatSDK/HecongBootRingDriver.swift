// 首屏圈接线层(app-sdk-plan.md §11.4 分工里「VC 那一半」,从 HecongChatViewController 拆出)。
//
// 三件套各管一件事:
//   · HecongBootRingState —— 纯状态机,只吐指令(可单测);
//   · HecongBootWaitView —— 只照指令画;
//   · 本类 —— 把事件喂进状态机,把 `schedule` / `cancel` 变成真计时(到点再喂 `.timer(t)`)、
//     `report` 交给上报出口、其余交给 BootWaitView。
// VC 只在事件发生处调 `feed`(导航开始 / ready / content-shown / notice-shown / 失败 / 销毁 / 池)。

import UIKit
import WebKit

final class HecongBootRingDriver {
  private var state = HecongBootRingState()
  private let ring = HecongBootWaitView()
  /// 状态机排上的真计时
  private var timers: [HecongBootRingState.Timer: DispatchWorkItem] = [:]
  /// 圈与 WebView 同挂在 VC 的 view 上(同一坐标系,圆心直接用 webView.center)
  private weak var host: UIView?
  private weak var webView: WKWebView?
  /// 30s 上报出口(VC 落成 HecongErrorReporter,带渠道 ID)
  private let report: (String) -> Void

  init(host: UIView, webView: WKWebView, report: @escaping (String) -> Void) {
    self.host = host
    self.webView = webView
    self.report = report
  }

  deinit { timers.values.forEach { $0.cancel() } }

  /// WebView frame 刚变(HecongKeyboardLayoutGuard.onWebViewFrameChange,frame 的唯一设置点)→ 圆心跟着走
  func webViewFrameDidChange() {
    if let wv = webView { ring.layout(center: wv.center) }
  }

  /// 唯一喂入口。`note` 只进 DEBUG 日志(如 content-shown 的 reason,壳逻辑不看)。
  func feed(_ event: HecongBootRingState.Event, note: String? = nil) {
    let now = Int(DispatchTime.now().uptimeNanoseconds / 1_000_000) // 单调时钟毫秒
    let commands = state.handle(event, now: now)
    #if DEBUG
      // 验收对帧用(§11.7):输入 / 输出带时间戳
      let line = "boot-ring t=\(now) \(event)\(note.map { "(\($0))" } ?? "") -> \(commands)"
      print("[HecongChat] " + line.replacingOccurrences(of: "HecongChatSDK.HecongBootRingState.", with: ""))
    #endif
    commands.forEach(run)
  }

  private func run(_ command: HecongBootRingState.Command) {
    switch command {
    case .attach:
      // 先按当前 webView.center 定一次位:首屏 frame 可能在导航开始前就定好了,frame 回调不会再来
      guard let host = host, let wv = webView else { return }
      ring.attach(to: host, center: wv.center)
    case .fadeIn: ring.fadeIn()
    case .fadeOut: ring.fadeOut()
    case .remove: ring.remove()
    case .suspendVisual: ring.suspendVisual()
    case .resumeVisual: ring.resumeVisual()
    case .schedule(let timer, let ms):
      timers[timer]?.cancel()
      let task = DispatchWorkItem { [weak self] in
        self?.timers[timer] = nil
        self?.feed(.timer(timer))
      }
      timers[timer] = task
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: task)
    case .cancel(let timer):
      timers.removeValue(forKey: timer)?.cancel()
    case .report(let message):
      // 协商成功 30s 还没收到 content-shown:只报不收圈(收圈由 60s 兜底)
      report(message)
    }
  }
}
