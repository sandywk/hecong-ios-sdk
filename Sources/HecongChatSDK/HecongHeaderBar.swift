// 标准档的原生标题栏(app-sdk-chat-entry.md §二 ① 标准档,刀1)——**只在没有宿主导航栏时自绘**。
//
// iOS 与安卓在这一档的分工不同(刻意的,各随各家平台):
//   · 被 push 进租户自己的 `UINavigationController` → **顶栏就是他家那条**,字体/返回箭头/
//     配色/暗色全自动一致,SDK 一个像素都不画(这也是"完全一致档"在 iOS 上白捡的原因);
//   · 模态弹出、或宿主压根没有导航栏 → 以前是**一条顶栏都没有、也没退出口**(只剩系统手势),
//     本类就是来补这个洞的。
//
// 形态:左 chevron 返回 + **居中标题**(UINavigationBar 惯例;安卓那条是左对齐,不强求两端一致)。
// 图标用 **SF Symbol**(系统件,随系统版本自动跟进字重与视觉)—— 合「能用最新就用最新」(§零)。
// 配色默认吃系统语义色(`systemBackground` / `label`),深浅色自动跟随,零配置即得平台观感。
import UIKit

final class HecongHeaderBar: UIView {
  /// 标题栏内容高度(不含状态栏安全区;与 UINavigationBar 标准高度一致)
  static let contentHeight: CGFloat = 44

  private let titleLabel = UILabel()
  private let onBack: () -> Void

  /// 只在**没有宿主导航栏、且我们就是整屏的根**时才用到(见 setupOwnHeaderIfNeeded)。
  ///
  /// 🪦 曾有个 `sheet: Bool` 参数画"✕ 版"给弹层档用 —— 2026-08-20 删:弹层改走
  /// **系统导航栏 + 系统 `.close` 件**(owner 走查"手画的那条很粗糙"),自绘那版再无调用方。
  /// 别再加回来:同样的东西系统给得更好,而且跟租户自家其它弹层长得一致。
  init(config: HecongChatConfig, onLeave: @escaping () -> Void) {
    self.onBack = onLeave
    super.init(frame: .zero)

    backgroundColor = config.headerBackgroundColor ?? .systemBackground
    let fg = config.titleColor ?? .label

    let back = UIButton(type: .system)
    if let custom = config.backImage {
      back.setImage(custom, for: .normal) // 租户自备图标:原样用,不染色
    } else {
      let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
      back.setImage(UIImage(systemName: "chevron.left", withConfiguration: cfg), for: .normal)
      back.tintColor = fg
    }
    back.accessibilityLabel = config.resolveBackLabel() // 无障碍:朗读得出"返回"
    back.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

    titleLabel.text = config.resolveTitle()
    titleLabel.textColor = fg
    titleLabel.font = .systemFont(ofSize: 17, weight: .semibold) // UINavigationBar 标准
    titleLabel.textAlignment = .center
    titleLabel.lineBreakMode = .byTruncatingTail

    addSubview(back)
    addSubview(titleLabel)
    back.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      // 顶栏自己吃状态栏安全区:背景铺到屏幕顶,内容落在状态栏下方(与 H5 那条同款协调)
      back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
      back.bottomAnchor.constraint(equalTo: bottomAnchor),
      back.heightAnchor.constraint(equalToConstant: Self.contentHeight),
      back.widthAnchor.constraint(equalToConstant: 44), // 点击热区,不是图标尺寸
      titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      titleLabel.centerYAnchor.constraint(equalTo: back.centerYAnchor),
      // 标题左右各让开一个按钮宽,长标题截断而不是压到返回键上
      titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 56),
      titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -56),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("use init(config:onBack:)") }

  /// titleFollowsAgent 用:接待身份变了就换标题
  func setTitle(_ text: String) { titleLabel.text = text }

  @objc private func handleBack() { onBack() }
}
