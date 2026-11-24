// 断网兜底页的画面(app-sdk-plan.md §二:壳给"网络不可用"页 + 重试)。
// 从 HecongChatViewController.showOfflineView 原样搬出(2026-11-24,VC 行数关卡);
// 何时画 / 上报 / 通知宿主仍在 VC,这里只管长相。

import UIKit

enum HecongOfflineView {
  /// 铺满容器的兜底页:一句提示 + 「重试」按钮(点了调 retryTarget 的 retryAction)
  static func make(frame: CGRect, retryTarget: Any, retryAction: Selector) -> UIView {
    let container = UIView(frame: frame)
    container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.backgroundColor = .systemBackground

    let zh = Locale.preferredLanguages.first?.hasPrefix("zh") == true
    let label = UILabel()
    label.text = zh ? "网络不可用,请检查网络后重试" : "Network unavailable. Please check and retry."
    label.textColor = .secondaryLabel
    label.font = .systemFont(ofSize: 15)
    label.numberOfLines = 0
    label.textAlignment = .center

    let button = UIButton(type: .system)
    button.setTitle(zh ? "重试" : "Retry", for: .normal)
    button.addTarget(retryTarget, action: retryAction, for: .touchUpInside)

    let stack = UIStackView(arrangedSubviews: [label, button])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 32),
    ])
    return container
  }
}
