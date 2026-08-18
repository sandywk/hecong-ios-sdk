// 门面登记的身份 —— 供**之后才起来的**聊天视图重放(app-sdk-plan.md §10.1 门面层)。
//
// 为什么需要:租户的正确接法是"APP 一登录就把会员身份告诉客服 SDK",那时聊天页通常还没开。
// 视图自己的 pendingCommands 队列解决不了这个 —— 那是"视图已建、桥还没 ready"的排队,
// 而这里是"视图压根还不存在"。两级队列职责不同,别合并。
//
// 🔴 **保存的是"合并后的当前身份",不是命令流水**:
// 若存流水(identify → update → update 三条依次重放),同一个 userId 会被重复绑定,
// 每条 update 也各发一次请求;而新视图真正需要的只是"这个人现在是谁、资料是什么" ——
// 一条 identify 就够。合并式天然幂等,且多个聊天视图各自重放互不影响。

import Foundation

/// 待重放身份的合并容器(线程约束:只在主线程访问,与门面其余状态同)。
final class HecongPendingIdentity {
  private(set) var userId: String?
  private(set) var profile: [String: Any] = [:]
  private(set) var data: [String: Any] = [:]

  /// 有身份可重放(未 identify 或已 reset 时为 false)
  var hasIdentity: Bool { userId != nil }

  /// 绑定会员 —— **整份替换**(换人 = 干净重来,不能残留上一个人的资料字段)
  func identify(userId: String, profile: [String: Any]?, data: [String: Any]?) {
    self.userId = userId
    self.profile = profile ?? [:]
    self.data = data ?? [:]
  }

  /// 更新资料 —— **逐字段合并**(PATCH 语义,与 H5 侧 userUpdate 一致:没传的字段不动)
  func update(profile: [String: Any]?, data: [String: Any]?) {
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
/// 门面刻意**不认识具体的视图类** —— 只依赖这三个动作,将来若做原生 UI 或别的承载形态,
/// 实现这个协议即可接入,门面零改动(workflow.md §10.4 公共面不可破坏的前置设计)。
protocol HecongChatCommandTarget: AnyObject {
  func identify(userId: String, profile: [String: Any]?, data: [String: Any]?)
  func updateUser(profile: [String: Any]?, data: [String: Any]?)
  func resetUser()
}
