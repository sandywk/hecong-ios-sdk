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
// (对话链接落地页那份 CSS 转圈**继续留着**,那是浏览器环境,行为正常且已上线验证过。)
//
// 🔴 **长相 = H5 聊天窗 loading 屏那个圈,一比一**(2026-09-11,owner:"加载状态非常拉垮,跟 H5 不搭")。
// 病根:壳的圈让位之后,H5 在同一位置接着转**它自己的**圈(messenger `chrome-styles.ts`
// `.hc-screen[data-screen="loading"]::after`)。原先壳用系统 `UIActivityIndicatorView`(花瓣式)——
// 访客看到的是「系统花瓣 → 换成一个素净的灰环」,两段换皮。H5 那边刻意追求
// 「同一个圈从头转到尾、中途不换皮」(`chat-reveal-gate.ts`),壳这第一段把它破了。
// ⇒ 规格照抄 H5(改那边就要同步改这里,安卓同款):外径 26(22 内容 + 2×2 边框,H5 无全局
//   border-box)、线宽 2、底环 = panelBorder、弧 = panelTextMuted、整体不透明度 0.6、0.7s 一圈匀速。
//   颜色取默认模板的中性灰(壳在 config 到货前拿不到租户模板;中性灰对任何主题都不突兀)。

import UIKit

/// WebView 上层的进站占位转圈。挂载/摘除都由 `HecongChatViewController` 驱动。
///
/// 行为与官方对话链接落地页那份**逐条对齐**(同一套语义,别各写各的):
///   · `.4s` 延迟淡入 —— 快网下根本不出现,不制造"闪一下"的噪音;
///   · `60s` 自动淡出兜底 —— 整条链哑掉时不至于永远转下去误导访客
///     (与 `readyWatchdog` 的 20s 上报是两件事:那个只留痕不动 UI,这个只管画面不上报);
///   · 无文字 —— 语言中性,壳侧拿不到渠道 i18n;
///   · `isUserInteractionEnabled = false` —— 不挡住后面挂上来的真实画面。
///
/// 明暗**不自己解析**:由调用方传入它唯一的解析点(`resolvedColorScheme`,与容器垫色 /
/// 骨架底色同源)—— 与 `skeletonHtml` 头部那条"不猜深浅色"的墓碑同源。
final class HecongBootWaitView {
  private var ring: HecongBootRingView?
  private var fadeIn: DispatchWorkItem?
  private var autoHide: DispatchWorkItem?

  /// 延迟这么久才淡入(快网下整条链跑完也没到,访客根本看不到转圈)。同落地页 `.4s`。
  private static let fadeInDelay: TimeInterval = 0.4
  /// 兜底:转这么久还没被摘就自己淡出,别让访客对着一个永动的圈。同落地页 `60s`。
  private static let autoHideAfter: TimeInterval = 60
  /// ready 让位的淡出时长(见 `handOff`)
  private static let handOffFade: TimeInterval = 0.15

  /// 挂到 WebView 上层(幂等:重复调用只会重置计时,不会叠出两个圈)。
  func attach(to host: UIView, dark: Bool) {
    detach()
    let view = HecongBootRingView(dark: dark)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.isUserInteractionEnabled = false
    view.isAccessibilityElement = false
    view.alpha = 0
    host.addSubview(view)
    NSLayoutConstraint.activate([
      view.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      view.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      view.widthAnchor.constraint(equalToConstant: HecongBootRingView.outer),
      view.heightAnchor.constraint(equalToConstant: HecongBootRingView.outer),
    ])
    view.startSpinning()
    ring = view

    let showTask = DispatchWorkItem { [weak view] in
      UIView.animate(withDuration: 0.3) { view?.alpha = HecongBootRingView.restingAlpha }
    }
    fadeIn = showTask
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDelay, execute: showTask)

    let hideTask = DispatchWorkItem { [weak self] in self?.detach() }
    autoHide = hideTask
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideAfter, execute: hideTask)
  }

  /// 桥 ready 时的让位:**淡出**而不是一刀摘掉。H5 那个圈此刻刚挂上、延迟淡入中,
  /// 硬摘会让画面在两个圈之间"闪空"一下;淡出把交接抹平。还没淡入(快网)就直接摘。
  func handOff() {
    guard let view = ring else { return }
    // 淡入动画进行中时 alpha 读的是目标值,要看呈现层才知道此刻屏上是不是还透明
    guard (view.layer.presentation()?.opacity ?? Float(view.alpha)) > 0 else {
      detach()
      return
    }
    cancelTimers()
    ring = nil
    UIView.animate(
      withDuration: Self.handOffFade, delay: 0, options: [.beginFromCurrentState],
      animations: { view.alpha = 0 },
      completion: { _ in view.removeFromSuperview() })
  }

  /// 立即摘除(幂等)。调用点:画兜底页 / 重新 load / VC 销毁。
  func detach() {
    cancelTimers()
    ring?.removeFromSuperview()
    ring = nil
  }

  private func cancelTimers() {
    fadeIn?.cancel()
    fadeIn = nil
    autoHide?.cancel()
    autoHide = nil
  }
}

/// 底环 + 上方 90° 弧(= H5 那个圈的 `border` + `border-top-color`),整体匀速自转。
private final class HecongBootRingView: UIView {
  // ---- 以下全部照抄 H5 loading 圈(messenger chrome-styles.ts),改那边须同步改这里与安卓 ----
  static let outer: CGFloat = 26
  static let stroke: CGFloat = 2
  static let restingAlpha: CGFloat = 0.6
  private static let spinPeriod: CFTimeInterval = 0.7

  // 默认模板中性灰:底环 = panelBorder(cGray3),弧 = panelTextMuted(cGray7);
  // 亮值见 shared/theme-tokens.ts,暗值见 shared/theme-tokens-dark.ts
  private static let trackLight = UIColor(red: 0xE3 / 255, green: 0xE8 / 255, blue: 0xF0 / 255, alpha: 1)
  private static let arcLight = UIColor(red: 0x6A / 255, green: 0x75 / 255, blue: 0x85 / 255, alpha: 1)
  private static let trackDark = UIColor(red: 0x30 / 255, green: 0x36 / 255, blue: 0x3D / 255, alpha: 1)
  private static let arcDark = UIColor(red: 0x9D / 255, green: 0xA7 / 255, blue: 0xB3 / 255, alpha: 1)

  private let track = CAShapeLayer()
  private let arc = CAShapeLayer()

  init(dark: Bool) {
    super.init(frame: .zero)
    for (shape, color) in [
      (track, dark ? Self.trackDark : Self.trackLight),
      (arc, dark ? Self.arcDark : Self.arcLight),
    ] {
      shape.fillColor = nil
      shape.strokeColor = color.cgColor
      shape.lineWidth = Self.stroke
      layer.addSublayer(shape)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    // 线宽的一半内缩:描边骑在路径两侧,不内缩外沿会被裁掉
    let rect = bounds.insetBy(dx: Self.stroke / 2, dy: Self.stroke / 2)
    track.frame = bounds
    arc.frame = bounds
    track.path = UIBezierPath(ovalIn: rect).cgPath
    // CSS 的 border-top 占圆周正上方那 90°(UIKit 角度 0 在 3 点钟、顺时针为正)
    arc.path = UIBezierPath(
      arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: rect.width / 2,
      startAngle: -.pi * 3 / 4, endAngle: -.pi / 4, clockwise: true
    ).cgPath
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
    layer.add(spin, forKey: "hecong.spin")
  }
}
