// 键盘布局所有权(壳内唯一所有者)—— 双路:H5 认 `keyboard-inset` 时壳只逐帧"报数",
// WebView 尺寸全程不动;老 H5 退回"缩 WebView 到键盘上方"兜底。
//
// 为什么改成报数(2026-08-24,owner 真机"消息区从下往上多段滑动"定案;
// native/keyboard-and-viewport.md §三 #13):
// 旧路"UIView.animate 缩 frame"有三个不同步的运动源 —— ①图层动画只动原生层,网页内容按
// 最终小高度一次性重排,与图层动画错拍;②容器骤矮一大截,H5 消息列表 ResizeObserver 触发
// ~300ms smooth 吸底,是第二段肉眼滑动;③WKWebView 自带键盘规避(contentInset/滚动)未被
// 压制,动画窗口内偶发第三跳。逐帧报数模式下 H5 每帧只让几 px,吸底逐帧小步跟随 = 连续
// 单段运动,与安卓 0.3.4(HecongInsetsHost)同架构、同 H5 协议(`--hc-app-kb-bottom`)。
//
// 「给键盘腾地方」任意时刻只能有一个所有者(keyboard-and-viewport.md §一):
//   - H5 声明 `keyboard-inset`(ready 载荷 capabilities,VC 解析)→ 所有者 = H5,壳只报数;
//   - 老 H5 → 所有者 = 壳,缩 frame(Capacitor `resize:native` 同款,功能不缺、观感多段);
//   - WKWebView 自己的键盘规避两种模式下都要钳零(第三所有者,见 suppressWebKitAvoidance)。
//
// 逐帧数据源:键盘通知只给"终点 + 时长 + 曲线",不给逐帧值 —— 让一个隐形 tracker 视图
// 用同时长同曲线做动画,CADisplayLink 每帧读它的 presentation layer,拿到的就是键盘当前
// 位置的真值(Core Animation 求值,不是手算曲线)。全版本一条路(iOS 13+ 通用;
// keyboardLayoutGuide 仅 15+ 且我们无交互式拖拽收键盘场景 —— H5 触摸消息区即 blur,
// 走标准通知,不缺场景故不分档)。
//
// 边界:硬件键盘工具条 / iPad 悬浮键盘 → 交叠取实际相交高度,自然归零;
// frame 由本类全权持有(WebView 不用 autoresizing 高度),旋转经 hostDidLayout 重算。

import UIKit
import WebKit

final class HecongKeyboardLayoutGuard {
  private weak var hostView: UIView?
  private weak var webView: WKWebView?
  /// 顶部避让量(VC 注入:有原生导航栏 → safeAreaInsets.top;无 → 0 铺满,状态栏由 H5
  /// env(safe-area-inset-top) 自理 —— 标题栏背景延伸进状态栏,原生 APP 同款协调)
  private let topInset: () -> CGFloat
  /// H5 是否认 `--hc-app-kb-bottom`(ready 载荷 capabilities 含 'keyboard-inset',VC 解析持有)
  private let h5OwnsKeyboard: () -> Bool
  /// 注入出口(键盘遮挡 px, 底部安全区 px)—— VC 落成 evaluateJavaScript 写 CSS 变量,
  /// 与安卓 HecongChatView.injectCssInsets 同一对变量名
  private let injectKeyboardInsets: (Int, Int) -> Void

  /// 键盘与宿主视图的实际交叠高度(硬件键盘/悬浮键盘场景自然为 0)
  private var overlap: CGFloat = 0
  /// 逐帧采样源:UIView.animate 按系统时长+曲线驱动它的 frame.origin.y = 目标 overlap,
  /// CADisplayLink 读 presentation layer 拿当前帧真值。alpha 0 不可见但图层仍在层级里参与动画。
  private let tracker = UIView(frame: CGRect(x: -1, y: 0, width: 1, height: 1))
  private var displayLink: CADisplayLink?
  /// 动画代次:新键盘事件接管旧动画时,旧 completion 不得停掉新动画还在用的 display link
  private var animationToken = 0
  /// 上次注入值(变了才发 JS —— 停稳/无键盘时零 JS,同安卓 injected 去重)
  private var lastInjected: (kb: Int, inset: Int)?
  private var insetObservation: NSKeyValueObservation?
  private var offsetObservation: NSKeyValueObservation?

  init(
    hostView: UIView, webView: WKWebView, topInset: @escaping () -> CGFloat,
    h5OwnsKeyboard: @escaping () -> Bool,
    injectKeyboardInsets: @escaping (Int, Int) -> Void
  ) {
    self.hostView = hostView
    self.webView = webView
    self.topInset = topInset
    self.h5OwnsKeyboard = h5OwnsKeyboard
    self.injectKeyboardInsets = injectKeyboardInsets
    tracker.alpha = 0
    tracker.isUserInteractionEnabled = false
    hostView.addSubview(tracker)
    suppressWebKitAvoidance(webView)
    let center = NotificationCenter.default
    // WillChangeFrame 覆盖弹出/收起/换输入法/分离键盘全部场景;Hide 单独兜底
    center.addObserver(
      self, selector: #selector(keyboardWillChange(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    center.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    displayLink?.invalidate()
  }

  /// 宿主 viewDidLayoutSubviews 调用(旋转/分屏后按当前 overlap 重铺 frame;
  /// 报数模式下若注入过,还要按新的 safeAreaInsets 重报 —— 注入值一旦存在就压过 env(),
  /// 旋转后 home 条高度变了不重报会钉死旧值)
  func hostDidLayout() {
    applyFrame()
    if h5OwnsKeyboard(), lastInjected != nil { injectCurrent(overlap) }
  }

  /// 页面(重)加载:CSS 变量随旧文档销毁,注入去重基线一并清零(VC didStartProvisionalNavigation 调)
  func pageDidReset() { lastInjected = nil }

  /// 桥 ready 后模式可能切换(老 H5 缩过的 frame → 新 H5 要满高),重铺一次(VC ready 分支调)
  func modeDidChange() { applyFrame() }

  @objc private func keyboardWillChange(_ note: Notification) {
    guard let host = hostView,
      let endFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    else { return }
    // 键盘 frame 是屏幕坐标 → 转宿主坐标取交叠(present 半屏/分屏时不会多算)
    let converted = host.convert(endFrame, from: nil)
    overlap = max(0, min(host.bounds.maxY, host.bounds.maxY - converted.minY))
    animateAlongKeyboard(note)
  }

  @objc private func keyboardWillHide(_ note: Notification) {
    overlap = 0
    animateAlongKeyboard(note)
  }

  /// 跟键盘同时长同曲线:报数模式动 tracker(WebView 不动),兜底模式动 WebView frame
  private func animateAlongKeyboard(_ note: Notification) {
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
    let options: UIView.AnimationOptions = [
      UIView.AnimationOptions(rawValue: curveRaw << 16), .beginFromCurrentState,
    ]
    guard h5OwnsKeyboard() else {
      UIView.animate(withDuration: duration, delay: 0, options: options,
        animations: { self.applyFrame() })
      return
    }
    applyFrame() // 若上一刻还在兜底模式(frame 缩着),先铺回满高
    animationToken += 1
    let token = animationToken
    startDisplayLink()
    UIView.animate(
      withDuration: duration, delay: 0, options: options,
      animations: { self.tracker.frame.origin.y = self.overlap },
      completion: { _ in
        guard token == self.animationToken else { return } // 已被更新的键盘事件接管
        self.stopDisplayLink()
        self.injectCurrent(self.overlap) // 终值兜底:采样可能停在倒数一两帧
      })
  }

  private func startDisplayLink() {
    guard displayLink == nil else { return }
    // CADisplayLink 强持有 target → 经 weak 代理断环,否则本类永不释放
    let link = CADisplayLink(target: WeakDisplayLinkProxy(self), selector: #selector(WeakDisplayLinkProxy.tick))
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  private func stopDisplayLink() {
    displayLink?.invalidate()
    displayLink = nil
  }

  /// 每帧:读 tracker 的 presentation layer(动画当前真值)→ 注入
  fileprivate func onFrame() {
    injectCurrent(tracker.layer.presentation()?.frame.origin.y ?? overlap)
  }

  /// 注入一对值(与安卓 applyKeyboard 同一条公式):
  ///   键盘遮挡 = 当前交叠;底部安全区 = max(home 条 − 键盘, 0) —— WebView 满高后
  ///   env(safe-area-inset-bottom) 不随键盘归零(视图几何没变),必须由壳按公式给,
  ///   否则输入区悬在键盘上方一条 home 条的高度。停稳后安全区 0,输入区下露模板留白,
  ///   与安卓停稳态同口径(keyboard-and-viewport.md §三 #11)。
  private func injectCurrent(_ kb: CGFloat) {
    guard let host = hostView else { return }
    let kbPx = max(0, Int(kb.rounded()))
    let insetPx = max(0, Int((host.safeAreaInsets.bottom - kb).rounded()))
    if let last = lastInjected, last.kb == kbPx, last.inset == insetPx { return }
    lastInjected = (kbPx, insetPx)
    injectKeyboardInsets(kbPx, insetPx)
  }

  private func applyFrame() {
    guard let host = hostView, let wv = webView else { return }
    // 顶边:壳只避开壳自己画的 UI(原生导航栏,含其上状态栏;iOS 15+ 导航栏默认透明、
    // VC view 延伸到栏下,从 y=0 铺会让第一条消息被盖 —— 2026-08-17 实测)。无导航栏时
    // 铺满到顶,状态栏由 H5 env 自理(见 topInset 注释)。
    // 底边:报数模式满高(键盘那段由 H5 让);兜底模式避开键盘交叠。
    let top = topInset()
    let bottomCut = h5OwnsKeyboard() ? 0 : overlap
    wv.frame = CGRect(
      x: 0, y: top,
      width: host.bounds.width,
      height: max(0, host.bounds.height - top - bottomCut))
  }

  /// 钳零 WKWebView 自带的键盘规避(第三所有者,两种模式都要)。
  ///
  /// `contentInsetAdjustmentBehavior = .never`(VC 已设)只管**安全区**那套,**管不住**
  /// WKWebView 对键盘的自动 contentInset + "把聚焦输入框滚进可视区"的文档滚动 ——
  /// 键盘与 WebView 有交叠时它必然出手(报数模式下交叠常驻,不钳 = 双份让位)。
  /// 我们的页面是单页应用,文档自身永不滚(内部滚动全在 DOM 滚动容器里),
  /// 所以 contentInset ≠ 0 / 未缩放下 contentOffset ≠ 0 都只可能是 WebKit 塞进来的,钳零即可
  /// (Capacitor/Cordova 生态同款公开做法;缩放态不钳 —— 那时的偏移是用户捏合平移,合法)。
  private func suppressWebKitAvoidance(_ wv: WKWebView) {
    insetObservation = wv.scrollView.observe(\.contentInset, options: [.new]) { sv, _ in
      guard sv.contentInset != .zero else { return } // 钳回 .zero 会再触发一次 KVO,此判据即出口
      sv.contentInset = .zero
    }
    offsetObservation = wv.scrollView.observe(\.contentOffset, options: [.new]) { sv, _ in
      guard sv.zoomScale <= 1.01,
        sv.contentSize.height <= sv.bounds.height + 1,
        sv.contentOffset != .zero
      else { return }
      sv.setContentOffset(.zero, animated: false)
    }
  }
}

/// CADisplayLink → target 是强持有,经本代理弱引用回真身(iOS 计时器断环的标准做法)
private final class WeakDisplayLinkProxy: NSObject {
  private weak var target: HecongKeyboardLayoutGuard?
  init(_ target: HecongKeyboardLayoutGuard) { self.target = target }
  @objc func tick() { target?.onFrame() }
}
