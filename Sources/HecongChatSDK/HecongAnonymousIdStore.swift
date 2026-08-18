// anonymousId 镜像持久化(Keychain)— 桥协议 §二.2 镜像模型。
//
// 定位:壳**不自造号**,只做 localStorage 的外部镜像 —— 首次 ready / anonymousIdChanged
// 回写时持久化,下次启动 document-start 注回去当种子(仅 H5 本地为空时生效)。
// 选 Keychain 而非 UserDefaults:卸载重装不丢(app-sdk-plan.md §六"最稳、零合规风险")。
//
// 读写失败一律静默降级(返回 nil / 忽略)—— 镜像丢了 H5 走自生成链路,功能不受损
// (sdk-specific.md §0 稳定第一:失败模式必须是退化不是不可用)。

import Foundation
import Security

final class HecongAnonymousIdStore {
  private let service = "com.hecong.chat-sdk"
  private let account: String

  /// scope:同一 APP 内接多个渠道时用 config.anonymousIdScope 区分镜像(默认单渠道共用一份)
  init(scope: String?) {
    let suffix = (scope?.isEmpty == false) ? ".\(scope!)" : ""
    self.account = "anonymousId\(suffix)"
  }

  /// UserDefaults 降级层:Keychain 在部分环境**静默失败**(2026-08-17 模拟器实证:无签名
  /// 构建 SecItemAdd 报 errSecMissingEntitlement,镜像一直空,"清缓存不丢人"卖点静默失效)。
  /// 降级链 = Keychain(卸载重装不丢)→ UserDefaults(清 WebView 缓存仍不丢,仅卸载会丢)——
  /// 失败模式是"少一层持久度",不是功能失效(sdk-specific §0 稳定判据)。
  private var defaultsKey: String { "hecong.chat.\(account)" }

  func read() -> String? {
    var query = baseQuery()
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) {
      return value
    }
    return UserDefaults.standard.string(forKey: defaultsKey)
  }

  func write(_ value: String) {
    // 双写:UserDefaults 恒写(降级读的兜底),Keychain 尽力写(成功即享卸载重装不丢)
    UserDefaults.standard.set(value, forKey: defaultsKey)
    guard let data = value.data(using: .utf8) else { return }
    var query = baseQuery()
    let update: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
    if status == errSecItemNotFound {
      query[kSecValueData as String] = data
      // AfterFirstUnlock:后台/锁屏也可读(WebView 生命周期不确定);不入 iCloud 同步
      query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      SecItemAdd(query as CFDictionary, nil)
    }
  }

  private func baseQuery() -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
