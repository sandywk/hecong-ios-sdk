// 门面登记的"非身份"壳状态 —— 供之后才起来的聊天视图重放(app-sdk-plan.md §10.7)。
//
// 与 `HecongPendingIdentity` 同款哲学(见其头注释):**存"当前状态"不存命令流水**。
// 租户的正确接法是 APP 启动 / 进商品页时就把按钮注册好、把指派组设好,那时聊天页通常还没开;
// 视图起来后一次性重放当前状态即可,不必按顺序回放历史命令。
//
// 三类状态的重放语义各不相同,别混:
//   - routing:最后一次的值(覆盖式)
//   - 注册按钮:全量 Map(同 id 覆盖,注销即删)—— 视图重建后按钮必须还在,否则点开聊天
//     页发现"发送商品"没了,而租户代码早在启动时就注册过一次,不会再注册第二次
//   - 选择器数据:**刻意不重放**。它是"点按钮那一刻现取"的易变数据(库存/登录态),
//     缓存重放等于把陈旧列表推给下一个会话;真需要时租户在 didClickAction 回调里现给。

import Foundation

/// 待重放壳状态(线程约束:只在主线程访问,与门面其余状态同)。
final class HecongPendingShellState {
  private(set) var routing: HecongRouting?
  /// id → 注册数据(`registerAction` 的 payload);顺序不重要,按钮排序由 H5 注册表决定
  private(set) var actions: [String: [String: Any]] = [:]

  func setRouting(_ routing: HecongRouting?) {
    self.routing = routing
  }

  func registerAction(_ payload: [String: Any]) {
    guard let id = payload["id"] as? String, !id.isEmpty else { return }
    actions[id] = payload
  }

  func unregisterAction(_ id: String) {
    actions.removeValue(forKey: id)
  }

  /// 视图挂载时重放。**顺序:先 routing 再按钮** —— 无强依赖,但 routing 决定这次会话归谁,
  /// 早一点发出去少一点竞态(接待分配发生在首条消息,按钮只影响 UI)。
  func replay(into target: HecongChatCommandTarget) {
    if let routing = routing {
      target.sendCommand("setRouting", payload: ["routing": routing.payload()])
    }
    for payload in actions.values {
      target.sendCommand("registerAction", payload: payload)
    }
  }
}
