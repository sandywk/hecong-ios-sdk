// 门面登记的身份 —— 供**之后才起来的**聊天视图重放(app-sdk-plan.md §10.1 门面层)。
//
// 为什么需要:租户的正确接法是"APP 一登录就把会员身份告诉客服 SDK",那时聊天页通常还没开。
// 视图自己的 pendingCommands 队列解决不了这个 —— 那是"视图已建、桥还没 ready"的排队,
// 而这里是"视图压根还不存在"。两级队列职责不同,别合并。
//
// 🔴 **保存的是"合并后的当前身份",不是命令流水,但 identify 与 update 必须分两层存**:
// - 不存流水:若把 identify → update → update 三条依次重放,同一个 userId 会被重复绑定,
//   每条 update 也各发一次请求;新视图真正需要的只是"这个人现在是谁、资料是什么"。
// - 必须分两层(2026-09-05 客服 APP 接入实锤):后端 `identify` 是**空才补**(档案里已有值就不动,
//   保护客服在工作台手改过的资料),`update` 才是**强覆盖**。初版把 update 过的字段揉进 identify
//   那一份、重放时只发一条 identify —— 租户明明调的是 updateUser(APP 版本号这类会变的字段),
//   经壳一转手变成了 identify,后端一看档案里已有旧值就不动,**版本号永远停在第一次的值**。
//   全程零报错,只有合从支持看到客户的 APP 版本对不上才会暴露。
//   所以:`profile`/`data` 只存 identify 说过的那份;update 过的字段单独放 `updatedProfile`/
//   `updatedData`,重放时先 identify 基础份、再 userUpdate 补丁份(见 HecongChat.attachTarget)。

import Foundation

/// 待重放身份的合并容器(线程约束:只在主线程访问,与门面其余状态同)。
final class HecongPendingIdentity {
  private(set) var userId: String?
  /// identify 传的基础资料(重放时以 identify 发,后端"空才补")
  private(set) var profile: [String: Any] = [:]
  private(set) var data: [String: Any] = [:]
  /// update 过的字段(重放时以 userUpdate 发,后端"强覆盖")—— 只含被 update 碰过的 key
  private(set) var updatedProfile: [String: Any] = [:]
  private(set) var updatedData: [String: Any] = [:]

  /// 有身份可重放(未 identify 或已 reset 时为 false)
  var hasIdentity: Bool { userId != nil }

  /// 有 update 过的字段要补发(重放第二段的闸门)
  var hasUpdates: Bool { !updatedProfile.isEmpty || !updatedData.isEmpty }

  /// 绑定会员 —— **整份替换**(换人 = 干净重来,不能残留上一个人的资料字段,
  /// 也不能残留上一个人 update 过的字段)
  func identify(userId: String, profile: [String: Any]?, data: [String: Any]?) {
    self.userId = userId
    self.profile = profile ?? [:]
    self.data = data ?? [:]
    updatedProfile = [:]
    updatedData = [:]
  }

  /// 更新资料 —— **逐字段合并进补丁层**(PATCH 语义,与 H5 侧 userUpdate 一致:没传的字段不动)。
  /// 刻意不写回 `profile`/`data`:那份要保持"identify 原话",否则重放时补丁又会被当基础份发出去。
  func update(profile: [String: Any]?, data: [String: Any]?) {
    profile?.forEach { updatedProfile[$0] = $1 }
    data?.forEach { updatedData[$0] = $1 }
  }

  /// 登出 —— 清空。**必须连 profile/data 一起清**:只清 userId 会让下一个人重放时
  /// 带着上一个人的资料(2026-08-14 link 壳换人不换号那类事故的同款形态)。
  func reset() {
    userId = nil
    profile = [:]
    data = [:]
    updatedProfile = [:]
    updatedData = [:]
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
  /// 通用命令透传(桥协议 §三.2)。身份三件保留具名方法是因为它们要过门面的合并容器;
  /// 其余命令一律走这条 —— **H5 将来新增命令时壳零改动**(具名方法只是便利糖)。
  func sendCommand(_ type: String, payload: [String: Any]?)
}
