// 门面登记的身份 —— 供**之后才起来的**聊天视图重放(app-sdk-plan.md §10.1 门面层)。
//
// 为什么需要:租户的正确接法是"APP 一登录就把会员身份告诉客服 SDK",那时聊天页通常还没开。
// 视图自己的 pendingCommands 队列解决不了这个 —— 那是"视图已建、桥还没 ready"的排队,
// 而这里是"视图压根还不存在"。两级队列职责不同,别合并。
//
// 🔴 **保存的是"合并后的当前身份",不是命令流水**:若存流水,同一个 userId 会被重复绑定、每条
// 各发一次请求;新视图真正需要的只是"这个人现在是谁、资料是什么" —— 一条 identify 就够。
// 记法只有两条(与 H5 `IdentityIntent` 同形):
//   - 同一个人再次 identify → **逐字段合并**(后者覆盖前者;APP 里多处各传一部分资料是常态)
//   - 换了人 → **整份替换**(干净重来,上一个人的任何字段都不能跟到新人头上)
//
// 🪦 曾经分"identify 基础份 + update 补丁份"两层、重放两段(2026-09-05 上午,对应当时后端
// 「identify 空才补 / update 强覆盖」的分叉语义)。同日 owner 拍板:后端统一为传什么覆盖什么,
// SDK 只留一个 identify、`updateUser` 全链路删除,两层随之收回一层。

import Foundation

/// 待重放身份的合并容器(线程约束:只在主线程访问,与门面其余状态同)。
final class HecongPendingIdentity {
  private(set) var userId: String?
  private(set) var profile: [String: Any] = [:]
  private(set) var data: [String: Any] = [:]

  /// 有身份可重放(未 identify 或已 reset 时为 false)
  var hasIdentity: Bool { userId != nil }

  /// 记一次 identify:同一个人逐字段合并(PATCH,没传的字段不动),换了人整份替换。
  func identify(userId: String, profile: [String: Any]?, data: [String: Any]?) {
    if self.userId != userId {
      self.userId = userId
      self.profile = [:]
      self.data = [:]
    }
    profile?.forEach { self.profile[$0] = $1 }
    data?.forEach { self.data[$0] = $1 }
  }

  /// 登出 —— 清空。**必须连 profile/data 一起清**:只清 userId 会让下一个人重放时
  /// 带着上一个人的资料(2026-08-14 link 壳换人不换号那类事故的同款形态)。
  func reset() {
    userId = nil
    profile = [:]
    data = [:]
  }
}

/// 门面下发身份命令的接收方(聊天视图实现它)。
///
/// 门面刻意**不认识具体的视图类** —— 只依赖这几个动作,将来若做原生 UI 或别的承载形态,
/// 实现这个协议即可接入,门面零改动(workflow.md §10.4 公共面不可破坏的前置设计)。
protocol HecongChatCommandTarget: AnyObject {
  func identify(userId: String, profile: [String: Any]?, data: [String: Any]?)
  func resetUser()
  /// 通用命令透传(桥协议 §三.2)。身份两件保留具名方法是因为它们要过门面的合并容器;
  /// 其余命令一律走这条 —— **H5 将来新增命令时壳零改动**(具名方法只是便利糖)。
  func sendCommand(_ type: String, payload: [String: Any]?)
}
