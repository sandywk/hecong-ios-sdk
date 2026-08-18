// 权限门原生端(桥协议 §五 canUseAttach 缝)。
//
// H5 发 permission-request{requestId, kind} → 本模块判定/请求 → 壳回 permissionResult。
// H5 侧 3s 超时自动放行,所以:已授权→立即回 true;未定→弹系统请求,用户决定后再回
// (可能超 3s,迟到回执 H5 静默丢弃,系统层会再拦一次,行为仍正确);已拒→立即回 false
// (拒绝引导文案是壳/宿主的责任,H5 不重复弹 —— 本壳当前只回结果,引导交宿主 APP 后续按需)。
//
// kind 映射:camera→相机、microphone→麦克风;photo/file→true(WKWebView 的 <input type=file>
// 走系统选择器,无需相册权限 —— handoff-app-webview-host.md §一"iOS file input 原生支持")。
// 未知 kind → true 放行(双向兼容:新 H5 加新档,老壳不拦功能)。

import AVFoundation
import Foundation

enum HecongPermissionResolver {
  static func resolve(kind: String, completion: @escaping (Bool) -> Void) {
    switch kind {
    case "camera":
      resolveCapture(.video, completion: completion)
    case "microphone":
      resolveCapture(.audio, completion: completion)
    default:
      // photo / file / 未知新档:放行(系统选择器自带门槛,壳不重复设卡)
      completion(true)
    }
  }

  private static func resolveCapture(
    _ media: AVMediaType, completion: @escaping (Bool) -> Void
  ) {
    switch AVCaptureDevice.authorizationStatus(for: media) {
    case .authorized:
      completion(true)
    case .notDetermined:
      // 前置合规提醒:Info.plist 必须有 NSMicrophoneUsageDescription / NSCameraUsageDescription,
      // 缺失是闪退不是报错(sdk-public-api-contract.md §八)—— 接入 README 有 checklist
      AVCaptureDevice.requestAccess(for: media) { granted in
        DispatchQueue.main.async { completion(granted) }
      }
    default:
      completion(false)
    }
  }
}
