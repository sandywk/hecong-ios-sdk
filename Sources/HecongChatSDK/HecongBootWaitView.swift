// 进站占位转圈(原生绘制)—— 2026-08-27,owner 真机反馈「点开档位空白一两秒,原生 APP 通常很流畅」。
//
// 🔴 **为什么必须由原生画,而不是写在骨架 HTML 里**(实测逼出来的,别再往回改):
//
// 第一版是照官方对话链接落地页的做法,在骨架 HTML 里内联一个纯 CSS 转圈(`#hc-boot-wait`)。
// 在浏览器里验证完全正常(明暗两档、延迟淡入、能被插座的 clearBootWait 摘掉),
// **装进 APP 却一帧都看不到**。诊断过程:
//   ① 疑心 `.4s` 延迟太长 → 改成 0s,仍看不到;
//   ② 疑心同步 `<script src>` 阻塞解析 → 加 `defer`,仍看不到;
//   ③ 把整个占位换成 `position:fixed;inset:0;background:red` 的**满屏红块** —— **依然一帧都没有**。
// ⇒ 结论:**WKWebView 在插座到货之前根本不绘制任何内容**。那 1~2 秒的白不是"页面画了白",
//   而是 WebView 还完全没上画面、透出下面容器的垫色(壳设了 `isOpaque=false`)。
//   骨架 HTML 里放什么都没用 —— 这不是"内容不够显眼",是那块画布还没开张。
//
// ⇒ 占位只能由**壳自己画在 WebView 上层**。这反而更对:原生转圈零等待、
//   不受 WebView 绘制策略摆布 —— 也正是「原生 APP 该有的流畅感」这个诉求本来的意思。
//
// 🔴 **App 里只有一个圈**(2026-11-24,app-sdk-plan.md §十一;协议 link-sdk-app-bridge.md §四.2):
// 双方都声明 `boot-ring` 时,从骨架页开始导航到首屏结束**只有这个原生圈**,H5 首屏不画圈,
// 首屏结束发 `content-shown` 收圈;老 H5 退回 ready 时 120ms 淡出。
// 什么时候挂 / 淡入 / 收 / 摘**全由 `HecongBootRingState` 决定**,本类只照指令画,不持有任何计时。
//
// 🪦 旧规格作废(0.6.2「与 H5 loading 圈一比一」对的是 messenger 圈;H5 首屏圈 2026-11-24 已换
// `web-sdk-motion.md §9.3`):透明度 .6、浅 #E3E8F0/#6A7585 / 深 #30363D/#9DA7B3 模板灰(按明暗传 `dark`)、
// 淡入 0.3s easeInOut、交接 0.15s、居中在整个 VC(有导航栏时比 WebView 中心低约 51pt)。
// 现规格 = H5 首屏圈同一份(唯一存放处 `packages/link-sdk/src/boot-ring-spec.ts`),中性灰深浅同一套、
// 圆心 = WebView frame 中心(§11.3)。改规格先改 boot-ring-spec.ts,再改这里与安卓;
// 常量一行一个字面量,供规格对账测试用正则读(§11.2「机器对账」)。

import UIKit

/// WebView 上层的进站占位转圈。只照 `HecongBootRingState` 的指令画(VC 转发)。
///
/// 不可点、不进无障碍树、不占布局(`isUserInteractionEnabled = false`,不挡后面的真实画面)。
/// 与 WebView 同挂在 VC 的 `view` 上(同一坐标系,圆心直接用 `webView.center`)——
/// **不往 WKWebView 里 addSubview**:会被它自己的内容层盖住(实测一帧都看不到)。
final class HecongBootWaitView {
  private var ring: HecongBootRingView?
  /// 收尾动画(fadeOut);摘圈时一并停掉
  private var exitAnimator: UIViewPropertyAnimator?

  // ---- 规格(boot-ring-spec.ts / web-sdk-motion.md §9.3;改那边须同步改这里与安卓)----
  /// 淡入时长(standard 220ms,线性)
  static let fadeInDuration: TimeInterval = 0.22
  /// 减少动态效果时的淡入时长(micro 120ms)
  static let reducedFadeInDuration: TimeInterval = 0.12
  /// 收尾时长(micro 120ms;= HecongBootRingState.exitMs,单测对账)
  static let exitDuration: TimeInterval = 0.12
  /// 收尾曲线 cubic-bezier(0.4, 0, 1, 1)(exit 档)
  static let exitCurveX1: CGFloat = 0.4
  static let exitCurveY1: CGFloat = 0
  static let exitCurveX2: CGFloat = 1
  static let exitCurveY2: CGFloat = 1

  /// 挂上透明的圈、按 WebView 中心定位并开始转(在池里挂的,状态机紧跟一条 suspendVisual)
  func attach(to host: UIView, center: CGPoint) {
    remove()
    let view = HecongBootRingView(
      frame: CGRect(x: 0, y: 0, width: HecongBootRingView.outer, height: HecongBootRingView.outer))
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true
    view.alpha = 0
    view.center = center
    host.addSubview(view)
    view.startSpinning()
    ring = view
  }

  /// 圆心跟随 WebView frame(VC 在 keyboardGuard 的 onWebViewFrameChange 里调;键盘动画块内调则随之动画)
  func layout(center: CGPoint) {
    ring?.center = center
  }

  /// 220ms 线性淡入到 0.85;减少动态效果时缩到 120ms
  func fadeIn() {
    guard let view = ring else { return }
    let duration = UIAccessibility.isReduceMotionEnabled ? Self.reducedFadeInDuration : Self.fadeInDuration
    UIView.animate(
      withDuration: duration, delay: 0, options: [.curveLinear, .beginFromCurrentState],
      animations: { view.alpha = HecongBootRingView.restingAlpha })
  }

  /// 120ms 收尾,从**当前呈现透明度**开始;先取消未完成的淡入(同 H5 `data-out` 冻结出现动画的教训:
  /// 不取消的话淡入会和淡出抢同一个 alpha,闪出半透明残影)。跑完不自己摘 —— 摘由状态机 exit 计时到点发 remove。
  func fadeOut() {
    guard let view = ring else { return }
    let current = CGFloat(view.layer.presentation()?.opacity ?? Float(view.alpha))
    view.layer.removeAllAnimations() // 淡入是隐式 opacity 动画;转圈在子层,不受影响
    view.alpha = current
    let animator = UIViewPropertyAnimator(
      duration: Self.exitDuration,
      controlPoint1: CGPoint(x: Self.exitCurveX1, y: Self.exitCurveY1),
      controlPoint2: CGPoint(x: Self.exitCurveX2, y: Self.exitCurveY2),
      animations: { view.alpha = 0 })
    animator.startAnimation()
    exitAnimator = animator
  }

  /// 立刻摘(幂等)
  func remove() {
    exitAnimator?.stopAnimation(true)
    exitAnimator = nil
    ring?.removeFromSuperview()
    ring = nil
  }

  /// 入备用页池:暂停转圈(池里没人看;端出来从原相位接着转)
  func suspendVisual() { ring?.setSpinPaused(true) }

  func resumeVisual() { ring?.setSpinPaused(false) }
}

/// 底环 + 上方 90° 弧(= H5 那个圈的 `border` + `border-top-color`),整体匀速自转。
/// 转动放在子层 `spinner` 上,整体透明度放在本视图 —— 淡入淡出与转动互不干扰。
private final class HecongBootRingView: UIView {
  // ---- 以下照抄 boot-ring-spec.ts(web-sdk-motion.md §9.3),改那边须同步改这里与安卓 ----
  /// 外径 26 = 内容 22 + 线宽 2 × 2
  static let outer: CGFloat = 26
  static let stroke: CGFloat = 2
  /// 整体透明度(静止态)
  static let restingAlpha: CGFloat = 0.85
  /// 0.7s 一圈,匀速无限
  private static let spinPeriod: CFTimeInterval = 0.7
  /// 底环 rgba(128,128,128,0.26) —— 中性灰,深浅色同一套,不跟模板变
  private static let trackColor = UIColor(red: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 0.26)
  /// 弧 #7d8796
  private static let arcColor = UIColor(red: 0x7D / 255, green: 0x87 / 255, blue: 0x96 / 255, alpha: 1)

  private let spinner = CALayer()
  private let track = CAShapeLayer()
  private let arc = CAShapeLayer()

  override init(frame: CGRect) {
    super.init(frame: frame)
    layer.addSublayer(spinner)
    for (shape, color) in [(track, Self.trackColor), (arc, Self.arcColor)] {
      shape.fillColor = nil
      shape.strokeColor = color.cgColor
      shape.lineWidth = Self.stroke
      spinner.addSublayer(shape)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 线宽的一半内缩:描边骑在路径两侧,不内缩外沿会被裁掉
    let rect = bounds.insetBy(dx: Self.stroke / 2, dy: Self.stroke / 2)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    spinner.frame = bounds
    track.frame = bounds
    arc.frame = bounds
    track.path = UIBezierPath(ovalIn: rect).cgPath
    // CSS 的 border-top 占圆周正上方那 90°(UIKit 角度 0 在 3 点钟、顺时针为正)
    arc.path = UIBezierPath(
      arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
      startAngle: -.pi * 3 / 4, endAngle: -.pi / 4, clockwise: true
    ).cgPath
    CATransaction.commit()
  }

  /// 系统「减弱动态效果」开着时不转,只留静态环 —— 对上 H5 的 prefers-reduced-motion。
  func startSpinning() {
    guard !UIAccessibility.isReduceMotionEnabled else { return }
    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
    spin.fromValue = 0
    spin.toValue = CGFloat.pi * 2
    spin.duration = Self.spinPeriod
    spin.repeatCount = .infinity
    spin.timingFunction = CAMediaTimingFunction(name: .linear)
    // 被 removeFromSuperview / 进后台时不自动清掉,回来接着转
    spin.isRemovedOnCompletion = false
    spinner.add(spin, forKey: "hecong.spin")
  }

  /// 暂停 / 恢复转动(Core Animation 标准做法:speed 置 0 并把 timeOffset 钉在当前相位)
  func setSpinPaused(_ paused: Bool) {
    if paused {
      guard spinner.speed != 0 else { return }
      let t = spinner.convertTime(CACurrentMediaTime(), from: nil)
      spinner.speed = 0
      spinner.timeOffset = t
    } else {
      guard spinner.speed == 0 else { return }
      let pausedAt = spinner.timeOffset
      spinner.speed = 1
      spinner.timeOffset = 0
      spinner.beginTime = 0
      spinner.beginTime = spinner.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
    }
  }
}
