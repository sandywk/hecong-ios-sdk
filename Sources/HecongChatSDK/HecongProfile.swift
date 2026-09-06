// 系统内置资料字段(2026-09-06 立;与安卓 `HecongProfile.kt` 逐字段对位)。
//
// 🔴 为什么要它:原先只能传裸字典 `[String: Any]`,键名全靠文档约定 —— 后端只认识
// name/avatar/phone/email 这四个(`webSdkIdentifyService.buildProfile`),其余一律忽略
// **且不给任何回执**。写成 "userName" 的表现就是"资料没上去,哪儿都不报错",
// 要到工作台逐字段核对才发现。换成本类之后拼写错误**当场编译不过**。
//
// 🔴 **必须是 `@objc` + NSObject 子类,不能用 Swift struct** —— 与 `HecongChatConfig`
// 同款理由(见其文件头):struct 对 ObjC 完全不可见,而租户里有大量 ObjC 存量工程。
// 属性用 `var` + 空构造(不是具名 init):这样 Swift 与 ObjC 写法几乎一样,
// 也避免"四个都是字符串的具名 init"在 ObjC 桥接后变成易错的位置参数。
import Foundation

/// 会员的系统内置资料。四个字段**全是可选**,不填的不下发(后端「传什么覆盖什么」,没传的不动)。
///
/// ```swift
/// // Swift
/// let p = HecongProfile()
/// p.name = "张三"; p.phone = "13800000000"
/// HecongChat.shared.identify(userId: "u_1001", profile: p)
/// ```
/// ```objc
/// // ObjC
/// HecongProfile *p = [HecongProfile new];
/// p.name = @"张三"; p.phone = @"13800000000";
/// [HecongChat.shared identifyWithUserId:@"u_1001" profile:p data:nil];
/// ```
@objc(HecongProfile)
public final class HecongProfile: NSObject {
  /// 会员昵称 / 姓名 —— 客服会话列表里显示的那个名字
  @objc public var name: String?

  /// 头像 URL(http/https)
  @objc public var avatar: String?

  /// 手机号。⚠️ 会作为**身份标识**参与跨设备识别与客户合并,别拿它填占位值
  @objc public var phone: String?

  /// 邮箱。⚠️ 同 ``phone``,会参与身份识别
  @objc public var email: String?

  @objc public override init() { super.init() }

  /// 转成协议要的字典。**只放非空且非空白的字段** ——
  /// 传空串会被后端当"要把这个字段清空"(传什么覆盖什么),不是"不传"。
  /// - Returns: 四个字段都没填时返回 nil(调用方据此整块不下发)
  internal func toDictionaryOrNil() -> [String: Any]? {
    var out: [String: Any] = [:]
    func put(_ key: String, _ value: String?) {
      guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return }
      out[key] = v
    }
    put("name", name)
    put("avatar", avatar)
    put("phone", phone)
    put("email", email)
    return out.isEmpty ? nil : out
  }
}

/// `identified` 事件里「被后端丢弃的自定义字段名」的解析(与安卓 `parseIgnoredKeys` 对位)。
///
/// 抽成独立入口是为了**可测**:桥事件解析原本埋在 `HecongChatViewController.handleNotify`
/// 里,那要真 WebView 才跑得到;而端到端要触发它还得凑齐「已建档 + data 含未定义 key」
/// 两个前提(2026-09-06 真机没凑到),更没法当回归钉。
///
/// 容错口径同 §4.5 铁律:字段缺失 / 类型不对 / 空数组 / 空串元素,一律当"没有",绝不崩。
enum HecongIgnoredKeys {
  static func parse(_ payload: [String: Any]?) -> [String] {
    guard let raw = payload?["ignoredKeys"] as? [Any] else { return [] }
    return raw.compactMap { $0 as? String }.filter { !$0.isEmpty }
  }
}
