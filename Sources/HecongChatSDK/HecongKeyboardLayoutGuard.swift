// 键盘布局所有权(壳内唯一所有者)—— 键盘弹出时把 WebView 缩到键盘上方。
//
// 为什么(2026-08-17 调研定案,现象 = 输入区与键盘之间悬空一条):
// 「给键盘腾地方」任意时刻只能有一个所有者(H5 侧 web-sdk-mobile-baseline.md §4.1 同款铁律,
// 此处升维到 壳 ↔ H5):
//   - 浏览器里布局视口不缩(iOS Safari 不支持 interactive-widget),所有者只能是 H5 的
//     keyboard-binder(visualViewport 算键盘高度 → 底部内衬自提);
//   - WKWebView 里若不管,WebKit 自己的键盘规避(contentInset/滚动)+ H5 内衬**两个所有者
//     同时干活** → 双份补偿 = 空隙。
// 方案 = 壳当唯一所有者:监听键盘 frame 变化,把 WebView 高度缩到键盘上方(业界既定路径:
// Capacitor Keyboard 默认 `resize: native` 模式,Ionic 生态生产验证多年)。缩完后
// 布局视口 == 可视视口 → H5 算出键盘高度 ≈ 0 **自动零介入**,WebKit 也无交叠可规避 ——
// 三方天然互斥,H5 零改动、无桥协商;vh/固定定位全部正确,效果最接近原生。
// Android 对照:windowSoftInputMode=adjustResize 由系统做同一件事(壳 README 已列宿主要求)。
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
  /// 键盘与宿主视图的实际交叠高度(硬件键盘/悬浮键盘场景自然为 0)
  private var overlap: CGFloat = 0

  init(hostView: UIView, webView: WKWebView, topInset: @escaping () -> CGFloat) {
    self.hostView = hostView
    self.webView = webView
    self.topInset = topInset
    let center = NotificationCenter.default
    // WillChangeFrame 覆盖弹出/收起/换输入法/分离键盘全部场景;Hide 单独兜底
    center.addObserver(
      self, selector: #selector(keyboardWillChange(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    center.addObserver(
      self, selector: #selector(keyboardWillHide(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
  }

  deinit { NotificationCenter.default.removeObserver(self) }

  /// 宿主 viewDidLayoutSubviews 调用(旋转/分屏后按当前 overlap 重铺 frame)
  func hostDidLayout() { applyFrame() }

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

  /// 跟键盘同时长同曲线动画,WebView 底边与键盘顶边同步移动(不同步 = 视觉脱节)
  private func animateAlongKeyboard(_ note: Notification) {
    let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
    let curveRaw = (note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt) ?? 7
    UIView.animate(
      withDuration: duration, delay: 0,
      options: [UIView.AnimationOptions(rawValue: curveRaw << 16), .beginFromCurrentState],
      animations: { self.applyFrame() })
  }

  private func applyFrame() {
    guard let host = hostView, let wv = webView else { return }
    // 顶边:壳只避开壳自己画的 UI(原生导航栏,含其上状态栏;iOS 15+ 导航栏默认透明、
    // VC view 延伸到栏下,从 y=0 铺会让第一条消息被盖 —— 2026-08-17 实测)。无导航栏时
    // 铺满到顶,状态栏由 H5 env 自理(见 topInset 注释)。底边避开键盘交叠。
    // 顶/底同归本类一个所有者管(native/keyboard-and-viewport.md §一)。
    let top = topInset()
    wv.frame = CGRect(
      x: 0, y: top,
      width: host.bounds.width,
      height: max(0, host.bounds.height - top - overlap))
  }
}
