// 本地骨架页承载(WKURLSchemeHandler)—— 装载形态 2026-08-17 改版的 iOS 半边。
//
// 为什么不加载线上 link 页:入口域名是全租户共享单点,国内环境有被投诉连坐屏蔽的真实
// 风险(老渠道逼租户自购域名即此因);静态资源域极少被屏蔽。改为:壳内生成最小骨架 HTML
//(本 handler 承载)→ 骨架从静态域拉插座 JS → chunk/版本仍由后端 config 指针控制。
// 业界同款 = Capacitor(WKURLSchemeHandler + localhost 主机名,生产验证多年)。
// Android 对应物 = WebViewAssetLoader(HecongChatView)。
//
// scheme 不能用 http/https(WKWebView 保留字);host=localhost 的原因见常量注释。

import Foundation
import WebKit

final class HecongLocalSchemeHandler: NSObject, WKURLSchemeHandler {
  private let loaderUrl: String
  init(loaderUrl: String) {
    self.loaderUrl = loaderUrl
  }

  func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
    guard let url = task.request.url else { return }
    // 唯一资源就是骨架页(插座/chunk/资产全走线上域,不经本 handler);
    // 其余路径(如内核探测)也回骨架,幂等无害
    let data = Data(
      HecongBridgeConstants.skeletonHtml(loaderUrl: loaderUrl).utf8)
    let response = URLResponse(
      url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8")
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
    // 骨架同步生成即完,无可取消的进行中工作
  }
}
