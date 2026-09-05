// 找"当前前台最上层"的控制器 —— 给不传 presenter 的打开重载用(app-sdk-chat-entry.md §二·补)。
//
// 为什么要它(2026-09-05 客服 APP SwiftUI 接入实锤):初版 `push(from:)` / `presentSheet(from:)` /
// `presentImmersive(from:)` 都要租户递一个控制器。UIKit 工程随手就有;**SwiftUI 工程按钮回调里
// 没有 self**,租户得自己写"connectedScenes → 前台窗口 → rootViewController → 沿 presented 链爬到
// 最上层"这十几行,而且各写各的容易找错(多 scene / 已弹着层时)。安卓传 context 哪都拿得到,
// 两端体验不对等。Intercom / Zendesk 的 `present()` 一律不要 presenter,这是 SDK 该兜的活。
// owner 拍板零包袱一步到位:带 presenter 的入参**直接删掉**,不留兼容重载(本 SDK 未上线,没人在用)。
//
// 边界(§0 稳定第一):找不到就返回 nil,由门面把打开方法退化成"什么都不做 + 返回 nil",
// 绝不 crash;找错的代价只是弹在了不理想的层上,功能仍在。

import UIKit

enum HecongPresenterResolver {
  /// 前台活动窗口。多 scene(iPad 分屏 / 多窗口)按「前台活动 > 前台非活动 > 后台」取,
  /// 同一 scene 内优先 keyWindow,退而取第一个可见窗口。
  static func foregroundWindow() -> UIWindow? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .sorted { rank($0.activationState) < rank($1.activationState) }
    for scene in scenes {
      if #available(iOS 15.0, *), let key = scene.keyWindow { return key }
      if let key = scene.windows.first(where: { $0.isKeyWindow }) { return key }
      if let visible = scene.windows.first(where: { !$0.isHidden }) { return visible }
    }
    return nil
  }

  /// 从 root 沿 presented 链与容器(导航栈 / Tab)走到最上层可见控制器。
  ///
  /// - 正在关闭中的弹层不算"最上层"(往它上面弹会随它一起消失)
  /// - 系统弹框 `UIAlertController` 不算(它不能再 present 别的东西)
  /// - 导航栈取栈顶、Tab 取选中页:递给 `present` 时 UIKit 会自己上溯到能弹的祖先,
  ///   递给 push 时用它的 `navigationController` 正好是当前那条栈
  static func topViewController(from root: UIViewController) -> UIViewController {
    var current = root
    while true {
      if let presented = current.presentedViewController,
        !presented.isBeingDismissed, !(presented is UIAlertController)
      {
        current = presented
        continue
      }
      if let nav = current as? UINavigationController, let top = nav.topViewController {
        current = top
        continue
      }
      if let tab = current as? UITabBarController, let selected = tab.selectedViewController {
        current = selected
        continue
      }
      return current
    }
  }

  /// 前台最上层控制器;前台没有任何窗口(极早调用 / 纯后台)时为 nil。
  static func topViewController() -> UIViewController? {
    guard let root = foregroundWindow()?.rootViewController else { return nil }
    return topViewController(from: root)
  }

  private static func rank(_ state: UIScene.ActivationState) -> Int {
    switch state {
    case .foregroundActive: return 0
    case .foregroundInactive: return 1
    case .background: return 2
    default: return 3
    }
  }
}
