// 壳侧错误上报 — GlitchTip/Sentry envelope 协议手写实现(app-sdk-plan.md §10.3)。
//
// ⛔ **绝不装全局未捕获异常钩子**(NSSetUncaughtExceptionHandler / signal handler):
// 租户 APP 几乎必然已接 Bugly / Firebase Crashlytics,我们一抢就可能把**他们自己的**
// 崩溃上报搞坏,且出事后他们查不出是我们干的 —— 嵌入式 SDK 的经典翻车方式。
// 本模块只报**我们自己主动接住**的失败(装载 / 桥 / HTTP / 权限流程)。
//
// ⛔ **不装 sentry-cocoa**:体积以百 KB 计 + 默认接管全局钩子(同上红线)。envelope 是
// 公开文档化的纯 JSON 协议(develop.sentry.dev/sdk/foundations/transport/envelopes),
// 拼包 + 一个 POST 就够 —— 与 H5 侧同款判断(web-sdk-error-monitoring.md §一)。
//
// 隐私(§10.3 第 3 条):只发错误信息/堆栈 + 渠道 ID + 系统版本/机型 + 壳版本。
// **不发**聊天内容、会员资料、anonymousId、URL query —— 租户隐私清单里我们保持干净。

import Foundation
import UIKit

/// 错误上报器。DSN 空 / 租户关闭 → 全链路 no-op(不建 session、不发请求)。
final class HecongErrorReporter {
  static let shared = HecongErrorReporter()

  /// 租户开关(config.errorReportingEnabled 同步过来);默认开 —— 关了出问题查无对证
  var isEnabled = true

  /// 单次进程内上报上限(防错误风暴打爆网络/电量,§10.3 限流)
  private let sessionLimit = 20
  /// 同签名去重窗口(秒)
  private let dedupeWindow: TimeInterval = 60

  private var sentCount = 0
  private var lastSentAt: [String: Date] = [:]
  private let queue = DispatchQueue(label: "com.hecong.chat-sdk.error-reporter")

  private init() {}

  /// 上报一条**已接住**的错误。scope = 出错的链路(load / bridge / http / permission / unread)。
  /// 失败静默(上报失败绝不影响业务,§0 稳定第一)。
  func report(scope: String, message: String, channelId: String?, extra: [String: String] = [:]) {
    guard isEnabled, !HecongBridgeConstants.errorDsn.isEmpty else { return }
    queue.async { [weak self] in
      guard let self = self else { return }
      let signature = "\(scope)|\(message)"
      let now = Date()
      guard self.sentCount < self.sessionLimit else { return }
      if let last = self.lastSentAt[signature], now.timeIntervalSince(last) < self.dedupeWindow {
        return
      }
      self.lastSentAt[signature] = now
      self.sentCount += 1
      self.send(scope: scope, message: message, channelId: channelId, extra: extra)
    }
  }

  // MARK: - envelope 拼装与发送

  private func send(scope: String, message: String, channelId: String?, extra: [String: String]) {
    guard let dsn = HecongDsn(HecongBridgeConstants.errorDsn),
      let url = URL(string: "\(dsn.endpoint)/api/\(dsn.projectId)/envelope/")
    else { return }

    let eventId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let timestamp = ISO8601DateFormatter().string(from: Date())
    var tags: [String: String] = [
      "sdk": "app-sdk-ios",
      "shell_version": HecongBridgeConstants.shellVersion,
      "scope": scope,
      // 系统版本是低基数维度,适合建索引(tags/extra 分工同 error-envelope.ts 头注释)
      "os_version": UIDevice.current.systemVersion,
    ]
    if let channelId = channelId { tags["channel_id"] = channelId }

    let event: [String: Any] = [
      "event_id": eventId,
      "timestamp": timestamp,
      "platform": "cocoa",
      "level": "error",
      "logger": "hecong-app-sdk",
      "release": HecongBridgeConstants.shellVersion,
      "environment": HecongBridgeConstants.errorEnvironment,
      "tags": tags,
      // 高基数现场参数走 extra(不建索引)
      "extra": extra.merging(["device_model": UIDevice.current.model]) { a, _ in a },
      "exception": [
        "values": [["type": scope, "value": message]]
      ],
    ]

    let header: [String: Any] = ["event_id": eventId, "sent_at": timestamp, "dsn": dsn.raw]
    let itemHeader: [String: Any] = ["type": "event"]
    guard let headerData = try? JSONSerialization.data(withJSONObject: header),
      let eventData = try? JSONSerialization.data(withJSONObject: event),
      let itemHeaderData = try? JSONSerialization.data(withJSONObject: itemHeader)
    else { return }
    // envelope = header\n itemHeader\n payload(换行分隔的 JSON,协议原文如此)
    var body = Data()
    body.append(headerData)
    body.append(0x0A)
    body.append(itemHeaderData)
    body.append(0x0A)
    body.append(eventData)

    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
    req.httpBody = body
    req.timeoutInterval = 10
    // 失败静默丢弃:上报本身出错不该再产生错误(不重试,防雪崩)
    URLSession.shared.dataTask(with: req).resume()
  }
}

/// DSN 解析(`https://<key>@<host>/<projectId>`)。形态不对 → nil,调用方 no-op。
struct HecongDsn {
  let raw: String
  let endpoint: String
  let projectId: String

  init?(_ dsn: String) {
    guard let url = URL(string: dsn), let host = url.host, let scheme = url.scheme else {
      return nil
    }
    let projectId = url.lastPathComponent
    guard !projectId.isEmpty, projectId != "/" else { return nil }
    self.raw = dsn
    self.projectId = projectId
    let port = url.port.map { ":\($0)" } ?? ""
    self.endpoint = "\(scheme)://\(host)\(port)"
  }
}
