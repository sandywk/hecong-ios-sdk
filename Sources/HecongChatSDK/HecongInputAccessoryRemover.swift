// 去掉 WKWebView 键盘上方的系统表单辅助条(上下箭头 + 完成)。
//
// 为什么:那条辅助条是给"网页表单逐项填写"设计的,聊天输入框只有一个,上下箭头无处可去,
// 「完成」还会收起键盘打断输入 —— 对聊天场景是纯干扰。Intercom / Zendesk 等成熟客服 SDK
// 均移除。WKWebView 无公开开关,业界通用做法 = 运行时给内容视图(WKContent*)动态派生
// 子类,覆写 inputAccessoryView 返回 nil(不改系统类本身,只影响本 WebView 实例)。
//
// 稳定第一(sdk-specific.md §0):按类名前缀嗅探,系统改名/找不到 → 静默保留系统条,
// 功能不受损;失败模式是"少一点细腻",不是不可用。

import UIKit
import WebKit

enum HecongInputAccessoryRemover {
  static func remove(from webView: WKWebView) {
    guard
      let target = webView.scrollView.subviews.first(where: {
        String(describing: type(of: $0)).hasPrefix("WKContent")
      }),
      let targetClass = object_getClass(target)
    else { return }

    let subclassName = "\(NSStringFromClass(targetClass))_HecongNoAccessory"
    // 同名派生类只注册一次(多实例/重进场景复用)
    if let existing = NSClassFromString(subclassName) {
      object_setClass(target, existing)
      return
    }
    guard let subclass = objc_allocateClassPair(targetClass, subclassName, 0) else { return }
    let selector = #selector(getter: UIResponder.inputAccessoryView)
    if let method = class_getInstanceMethod(targetClass, selector) {
      let block: @convention(block) (AnyObject) -> UIView? = { _ in nil }
      class_addMethod(
        subclass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
    }
    objc_registerClassPair(subclass)
    object_setClass(target, subclass)
  }
}
