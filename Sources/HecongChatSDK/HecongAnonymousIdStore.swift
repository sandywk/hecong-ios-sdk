// anonymousId 镜像持久化(应用沙盒 UserDefaults)— 桥协议 §二.2 镜像模型。
//
// 定位:壳**不自造号**,只做 H5 真源的外部镜像 —— 首次 ready / anonymousIdChanged 回写时
// 持久化,下次启动 document-start 注回去当种子(仅 H5 本地为空时生效)。
// 清 WebView 缓存不影响本存储,"清缓存不丢人"由此达成;**卸载重装会丢 —— 这是刻意的**。
//
// 🪦 2026-08-21 砍掉 Keychain 层(owner 定):
//   曾用「Keychain(卸载重装不丢)→ UserDefaults 兜底」两层。砍掉的三条理由:
//   ① **语义本就不该跨卸载** —— 用户卸载重装还被认成同一个人,这不符合任何人的预期,
//      我们对外也从没承诺过。要跨设备/跨重装延续记录,正解是让他**登录会员**,
//      后端认出人就把记录还给他(`firstPartyCustomerLookupService.resolveAnonymousIdForClient`)。
//   ② **两端做不到一致** —— 安卓没有 Keychain 等价物,注释里本就写着"既定取舍"。
//      iOS 认得出、安卓认不出 = 租户一测就发现两端行为不一样,必然投诉。
//   ③ **它自己就不可靠** —— 2026-08-17 模拟器实证:无签名构建下 SecItemAdd 报
//      errSecMissingEntitlement,写入静默失败,镜像恒空。为此才加的兜底层,一个功能两套实现。
//   砍掉是**纯删除、零迁移**:原先双写,数据本来就有一份在 UserDefaults 里,读它即可。
//
// 读写失败一律静默降级(返回 nil / 忽略)—— 镜像丢了 H5 走自生成链路,功能不受损
// (sdk-specific.md §0 稳定第一:失败模式必须是退化不是不可用)。

import Foundation

final class HecongAnonymousIdStore {
  private let key: String

  /// scope:同一 APP 内接多个渠道时用 config.anonymousIdScope 区分镜像(默认单渠道共用一份)
  init(scope: String?) {
    let suffix = (scope?.isEmpty == false) ? ".\(scope!)" : ""
    // key 与砍 Keychain 之前的 UserDefaults 降级层完全一致 —— 老装机的镜像原样接得上
    self.key = "hecong.chat.anonymousId\(suffix)"
  }

  func read() -> String? {
    UserDefaults.standard.string(forKey: key).flatMap { $0.isEmpty ? nil : $0 }
  }

  func write(_ value: String) {
    UserDefaults.standard.set(value, forKey: key)
  }
}
