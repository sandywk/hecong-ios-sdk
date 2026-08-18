// 会话事件信封分发(桥协议 §四 `event`;capability 'session-events')。
//
// 从 HecongChatViewController 下沉:视图只管"收到 event 就交给这里",怎么分发在本文件
// (.claude/rules/splitting-guide.md §3.5.1 编排/实现分离的原生版)。

import Foundation

/// H5 会话事件 → 宿主回调的分发器。
///
/// 🔴 **两层设计的要点在于"漏了不坏事"**:
///   ① 具名便利糖 —— 下面 `switch` 里这张映射,只覆盖常用事件;
///   ② 通吃 `hecongChat(didReceiveEvent:payload:)` —— **一条不漏**,含将来 H5 才发明、
///      本壳完全不认识的事件。
///
/// 所以 ① 这张表**慢慢补就行,不是必须同步维护的登记表**:漏一条的后果仅仅是"少一个
/// 有类型的便利方法",事件本身照样经 ② 送达宿主。这跟"每个事件一个通知 type"的写法
/// 有本质区别 —— 那种写法下漏一条 = 事件彻底到不了宿主,而且要发原生包才能补
/// (原生包更新率远低于 H5,桥协议 §一 硬前提 3)。
enum HecongSessionEvents {

  /// 分发一条事件信封。
  ///
  /// - Parameters:
  ///   - payload: 桥通知 payload,形如 `{ name: "message:incoming", data?: {...} }`
  ///   - notify: 把一个回调动作施加到"该收的每个 delegate"上(视图侧负责与门面去重)
  static func dispatch(
    _ payload: [String: Any]?, notify: ((HecongChatDelegate) -> Void) -> Void
  ) {
    // name 缺失 = 不认识的信封形状(老壳撞新 H5 / 脏数据)→ 静默丢弃,不崩
    // (双向兼容铁律 1;上报交由调用方决定,避免脏数据刷爆上报配额)
    guard let name = payload?["name"] as? String, !name.isEmpty else { return }
    let data = payload?["data"] as? [String: Any]

    // ① 具名便利糖(有类型、不用解字典)
    switch name {
    case "message:incoming":
      if let d = data { notify { $0.hecongChat?(didReceiveIncomingMessage: message(from: d)) } }
    case "message":
      if let d = data { notify { $0.hecongChat?(didReceiveMessage: message(from: d)) } }
    case "conversation:start":
      if let id = data?["conversationId"] as? String, !id.isEmpty {
        notify { $0.hecongChatConversationDidStart?(id) }
      }
    case "conversation:end":
      let id = (data?["conversationId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      notify { $0.hecongChatConversationDidEnd?(id) }
    case "network:online":
      notify { $0.hecongChatNetworkDidChange?(true) }
    case "network:offline":
      notify { $0.hecongChatNetworkDidChange?(false) }
    default:
      // 没有具名糖的事件不是错误 —— 它照样会走下面的通吃回调
      break
    }

    // ② 通吃:一条不漏(**包括上面 default 分支里那些**)
    notify { $0.hecongChat?(didReceiveEvent: name, payload: data) }
  }

  /// 事件 payload → 对外消息投影。字段全部按"缺了就给空"处理(双向兼容铁律 3)
  private static func message(from d: [String: Any]) -> HecongMessage {
    let serverId = (d["serverId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    // createdAt 可能被 JSON 解成 Int / Double / NSNumber,统一取 NSNumber 再转
    let createdAt = (d["createdAt"] as? NSNumber)?.int64Value ?? 0
    return HecongMessage(
      serverId: serverId,
      from: d["from"] as? String ?? "",
      text: d["text"] as? String ?? "",
      contentType: d["contentType"] as? String ?? "",
      createdAt: createdAt)
  }
}

/// 消息的对外投影(契约 §六 `PublicMessageInfo` 的原生镜像)。
///
/// **刻意只给这几个字段** —— 内部消息模型绝不交出去(交了以后加个字段都可能砸到租户)。
/// 新增字段是兼容的,减字段不是,所以宁可先少给。
@objc(HecongMessage)
public final class HecongMessage: NSObject {
  /// 服务端消息 id;本地占位(还没发出去)时为 nil
  @objc public let serverId: String?
  /// 发送方:"visitor"(访客自己) / "agent"(人工客服) / "bot"(机器人) / "system"
  @objc public let from: String
  /// 纯文本内容(富消息取其可读文本;无文本内容时为空串)
  @objc public let text: String
  /// 内容类型:"text" / "image" / "video" / "file" / "audio" / "card" / …
  @objc public let contentType: String
  /// 服务端时间戳(毫秒)
  @objc public let createdAt: Int64

  init(serverId: String?, from: String, text: String, contentType: String, createdAt: Int64) {
    self.serverId = serverId
    self.from = from
    self.text = text
    self.contentType = contentType
    self.createdAt = createdAt
    super.init()
  }
}
