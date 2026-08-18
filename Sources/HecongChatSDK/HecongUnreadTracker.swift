// 未读跟踪 —— **默认关闭的 opt-in 能力**(app-sdk-plan.md §10.2,owner 2026-08-18 拍板)。
//
// 为什么默认关:很多租户只要"点进客服页能收发消息"就够;开这个 = 壳要伴随宿主 APP 生命周期
// 活动(轮询 + 回调),既是租户的额外开发量,也是我们对宿主 APP 的额外侵入面。
// 不需要的租户不该背这个代价。
//
// 弹药是现成的:GET /sdk/precheck(ADR-0014 §七 接口 A)**不连 WS**,一次 REST 返回
// 未读数 + 有无活跃对话。后端零改动、H5 零改动。
//
// 三道省资源闸门(§10.2,任一不过即零活动):
//   ① 租户显式 start —— 不调则本类根本不被创建;
//   ② 本地 anonymousId 镜像为空 = 从没聊过天 = 不可能有未读 → **一个请求都不发**;
//   ③ 前台才活动 —— 进后台立即停(不产生后台网络,国内商店审核检查项),回前台先立刻查一次。
//
// 失败一律**静默停手**(§0 稳定第一):token 401(渠道开了验票,原生不实现该算法)/ 网络失败
// → 放弃未读能力,聊天完全不受影响。

import Foundation
import UIKit

final class HecongUnreadTracker {
  private let channelId: String
  private let apiBase: String
  private let anonymousId: String
  private let interval: TimeInterval
  private let onChange: (Int) -> Void

  private var timer: Timer?
  /// ⚠️ token / lastCount / isStopped 三个状态**只在主线程读写**(Timer 在主线程触发,
  /// URLSession 回调在别的线程 —— 不收口就是数据竞争)。网络回调里一律 hop 回主线程再改。
  private var token: String?
  private var isStopped = false
  /// 聊天页开着时暂停 —— 那时 WS 是权威来源,H5 的 unread 通知直接喂门面(避免两个源打架)
  private var isPaused = false
  private var lastCount = -1

  /// - Parameter interval: 轮询间隔,下限 30s(防租户配出高频请求,§10.2)
  init(
    channelId: String, apiBase: String, anonymousId: String, interval: TimeInterval,
    onChange: @escaping (Int) -> Void
  ) {
    self.channelId = channelId
    self.apiBase = apiBase.hasSuffix("/") ? String(apiBase.dropLast()) : apiBase
    self.anonymousId = anonymousId
    self.interval = max(30, interval)
    self.onChange = onChange
  }

  func start() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(didEnterBackground),
      name: UIApplication.didEnterBackgroundNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(willEnterForeground),
      name: UIApplication.willEnterForegroundNotification, object: nil)
    resume()
  }

  func stop() {
    isStopped = true
    NotificationCenter.default.removeObserver(self)
    timer?.invalidate()
    timer = nil
  }

  deinit { stop() }

  /// 聊天页打开/关闭时切换(打开=暂停轮询,交给 WS;关闭=恢复并立刻查一次)
  func setPaused(_ paused: Bool) {
    guard isPaused != paused else { return }
    isPaused = paused
    if paused {
      timer?.invalidate()
      timer = nil
    } else {
      resume()
    }
  }

  // MARK: - 生命周期(闸门 ③)

  @objc private func didEnterBackground() {
    timer?.invalidate()
    timer = nil
  }

  @objc private func willEnterForeground() {
    guard !isPaused else { return }
    resume()
  }

  private func resume() {
    guard !isStopped else { return }
    timer?.invalidate()
    // 回前台/首次:先立刻查一次再起计时(不让用户干等一个轮询周期)
    poll()
    let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  // MARK: - 请求链路(token → precheck)

  private func poll() {
    if let token = token {
      fetchPrecheck(token: token)
    } else {
      fetchToken { [weak self] token in
        // hop 回主线程:token 是主线程独占状态(见字段注释)
        DispatchQueue.main.async {
          guard let self = self, !self.isStopped, let token = token else { return }
          self.token = token
          self.fetchPrecheck(token: token)
        }
      }
    }
  }

  /// POST /sdk/session/token —— body 与 H5 侧 token-fetcher 同形(channelId 走请求头 + body)。
  /// 401 = 渠道开了验票(attestation),原生不实现该算法 → **静默放弃未读能力**,不重试。
  private func fetchToken(completion: @escaping (String?) -> Void) {
    guard let url = URL(string: "\(apiBase)/sdk/session/token") else { return completion(nil) }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 15
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(channelId, forHTTPHeaderField: "X-Channel-Id")
    let body: [String: Any] = [
      "channelId": channelId,
      "anonymousId": anonymousId,
      // 自报壳类型必须与渠道 platform 一致,否则后端 400 VAL_PLATFORM_MISMATCH(桥协议 §二.1)
      "platform": "app",
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
      if let error = error {
        HecongErrorReporter.shared.report(
          scope: "unread", message: "token fetch failed: \(error.localizedDescription)",
          channelId: self?.channelId)
        return completion(nil)
      }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data,
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let token = json["token"] as? String
      else {
        // 非 200 后端自己有记录,客户端不重复上报(同 token-fetcher.ts 的口径)。
        // 停手不重试(401 = 渠道开了验票,原生不实现该算法 → 放弃未读能力)
        DispatchQueue.main.async { self?.stop() }
        return completion(nil)
      }
      completion(token)
    }.resume()
  }

  /// GET /sdk/precheck —— 拿未读数。失败静默(容错优先,precheck 本就是"乐观快照"不是承诺)。
  private func fetchPrecheck(token: String) {
    guard let url = URL(string: "\(apiBase)/sdk/precheck") else { return }
    var req = URLRequest(url: url)
    req.timeoutInterval = 15
    req.setValue(channelId, forHTTPHeaderField: "X-Channel-Id")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
      let isUnauthorized = (response as? HTTPURLResponse)?.statusCode == 401
      let unread: Int? = data
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        .flatMap { $0["unread"] as? Int }
      // 状态变更与回调统一回主线程(字段注释:主线程独占)
      DispatchQueue.main.async {
        guard let self = self, !self.isStopped else { return }
        if isUnauthorized {
          self.token = nil // 过期 → 下轮重取(不立即重试,避免失败风暴)
          return
        }
        guard let unread = unread, unread != self.lastCount else { return }
        self.lastCount = unread
        self.onChange(unread)
      }
    }.resume()
  }
}
