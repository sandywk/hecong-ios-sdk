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
// ⇒ 占位只能由**壳自己画在 WebView 上层**。这反而更对:原生转圈零等待、天然跟随宿主明暗、
//   不受 WebView 绘制策略摆布 —— 也正是「原生 APP 该有的流畅感」这个诉求本来的意思。
//
// (对话链接落地页那份 CSS 转圈**继续留着**,那是浏览器环境,行为正常且已上线验证过。)

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
/// 明暗**不解析、不传参**:`UIActivityIndicatorView` 用系统语义色,自动跟随宿主(含 App 用
/// `overrideUserInterfaceStyle` 强制的那种)—— 与 `skeletonHtml` 头部那条"不猜深浅色"的
/// 墓碑同源,这里连"猜"的机会都不给。
final class HecongBootWaitView {
  private weak var host: UIView?
  private var indicator: UIActivityIndicatorView?
  private var fadeIn: DispatchWorkItem?
  private var autoHide: DispatchWorkItem?

  /// 延迟这么久才淡入(快网下整条链跑完也没到,访客根本看不到转圈)。同落地页 `.4s`。
  private static let fadeInDelay: TimeInterval = 0.4
  /// 兜底:转这么久还没被摘就自己淡出,别让访客对着一个永动的圈。同落地页 `60s`。
  private static let autoHideAfter: TimeInterval = 60

  /// 挂到 WebView 上层(幂等:重复调用只会重置计时,不会叠出两个圈)。
  func attach(to host: UIView) {
    detach()
    self.host = host
    let spinner = UIActivityIndicatorView(style: .medium)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.isUserInteractionEnabled = false
    spinner.alpha = 0
    spinner.startAnimating()
    host.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])
    indicator = spinner

    let showTask = DispatchWorkItem { [weak spinner] in
      UIView.animate(withDuration: 0.3) { spinner?.alpha = 1 }
    }
    fadeIn = showTask
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeInDelay, execute: showTask)

    let hideTask = DispatchWorkItem { [weak self] in self?.detach() }
    autoHide = hideTask
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.autoHideAfter, execute: hideTask)
  }

  /// 摘除(幂等)。调用点:桥 ready(真实画面已就位)/ 画兜底页 / 重新 load / VC 销毁。
  func detach() {
    fadeIn?.cancel()
    fadeIn = nil
    autoHide?.cancel()
    autoHide = nil
    indicator?.stopAnimating()
    indicator?.removeFromSuperview()
    indicator = nil
    host = nil
  }
}
