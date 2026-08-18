// swift-tools-version:5.5
// 合从壳式 app-sdk — iOS 原生薄壳(app-sdk-plan.md §八)。
//
// 分发**只走 SPM**:Xcode 只认仓库根目录的 Package.swift,而本 SDK 在 monorepo 的
// native/ios/ 下 —— 故对外走公开分发仓(`pnpm native:sync-ios` 单向同步)。
// 本文件服务于「本地 path 依赖 / 分发仓同步」两条路,不指望在 monorepo 根被 Xcode 直接解析。
import PackageDescription

let package = Package(
  name: "HecongChatSDK",
  platforms: [.iOS(.v13)],
  products: [
    .library(name: "HecongChatSDK", targets: ["HecongChatSDK"])
  ],
  targets: [
    .target(name: "HecongChatSDK", path: "Sources/HecongChatSDK")
  ]
)
