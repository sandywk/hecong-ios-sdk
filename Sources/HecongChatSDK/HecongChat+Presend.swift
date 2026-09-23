// 带入咨询内容(web-sdk-presend.md §四)—— 从 HecongChat.swift 拆出的扩展(门面文件守 300 行硬线)。
// 与安卓 HecongChat.setPresend / clearPresend 同构:聊天页开着直接发,没开登记、视图挂载时重放一次。

import Foundation

extension HecongChat {

  /// 把访客正在看的东西带进聊天:`text` 填进输入框,`card` 摆在消息流末尾,**访客点了才发**。
  ///
  /// `card` 是卡片字典(只支持 product / order / article,字段同 `setPickerData` 的条目)。
  /// 可在打开聊天页之前调(自动重放一次);字段各自独立,只传其一只动那一样。
  /// 撤掉待发卡片用 `clearPresend()`。
  @objc public func setPresend(text: String?, card: [String: Any]? = nil) {
    var presend: [String: Any] = [:]
    if let text = text, !text.isEmpty { presend["text"] = text }
    if let card = card { presend["card"] = card }
    guard !presend.isEmpty else { return }
    sendPresend(presend)
  }

  /// 撤掉待发卡片(以及聊天页没开时登记、尚未生效的带入内容)。
  @objc public func clearPresend() {
    sendPresend(nil)
  }

  /// 聊天页开着 → 直接发;没开 → 登记,视图挂载时重放一次(HecongPendingShellState)
  private func sendPresend(_ presend: [String: Any]?) {
    guard hasLiveTarget else {
      pendingShell.mergePresend(presend)
      return
    }
    let payload: [String: Any] = ["presend": presend as Any? ?? NSNull()]
    forEachTarget { $0.sendCommand("setPresend", payload: payload) }
  }
}
