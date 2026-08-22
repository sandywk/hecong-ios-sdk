// 「导航栏隐藏时,系统侧滑返回仍然有效」的保活件。
//
// UIKit 的规矩:`UINavigationController` 自己当 `interactivePopGestureRecognizer` 的 delegate,
// 而它在**导航栏隐藏**时一律不让手势开始 —— 于是"隐藏系统导航栏、自己画顶栏"的页面
// (本 SDK 的沉浸档 push 形态、租户的嵌入档)侧滑返回就死了,只能点 ✕ / 自绘返回键。
// 2026-08-22 owner iPhone 真机:沉浸档 / 嵌入档"手势返回无效,客户退出来麻烦,租户会投诉"。
//
// 做法 = 业界标准解:接管 delegate,只在「栈里不止一页」时放行(根页放行会让 UIKit 卡死,
// 这是把 delegate 直接设 nil 的经典坑)。**只在 delegate 还是 UIKit 默认值(导航控制器自己)时
// 才接管** —— 宿主已经自己管了就不碰;离场时原样还回去。不动 `isEnabled`,宿主显式关掉的手势我们不复活。
// 规划:app-sdk-chat-entry.md §二(出口规则:有返回栈 → 系统侧滑必须可用)
import UIKit

final class HecongSwipeBackKeeper: NSObject, UIGestureRecognizerDelegate {
  private weak var navigationController: UINavigationController?
  private weak var originalDelegate: UIGestureRecognizerDelegate?
  private var installed = false

  init(navigationController: UINavigationController) {
    self.navigationController = navigationController
    super.init()
  }

  /// 接管(幂等)。返回 false = 没接管(宿主已自管 delegate / 无手势)。
  @discardableResult
  func install() -> Bool {
    guard !installed, let nav = navigationController, let pop = nav.interactivePopGestureRecognizer
    else { return installed }
    // delegate 不是导航控制器本身 = 宿主自己在管(或别人已接管),不抢
    guard pop.delegate == nil || pop.delegate === nav else { return false }
    originalDelegate = pop.delegate
    pop.delegate = self
    installed = true
    return true
  }

  /// 还回去(幂等)。只在 delegate 仍是我们时才还,别把宿主后来设的覆盖掉。
  func restore() {
    guard installed else { return }
    installed = false
    guard let pop = navigationController?.interactivePopGestureRecognizer, pop.delegate === self
    else { return }
    pop.delegate = originalDelegate
  }

  func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard let nav = navigationController else { return false }
    // 根页不放行(UIKit 会卡在半路);正在转场时不放行(连滑两次的竞态)
    return nav.viewControllers.count > 1 && nav.transitionCoordinator == nil
  }
}
