# Hecong Chat SDK (iOS)

合从客服 SDK —— iOS 原生壳。接入手册:https://docs.aihecong.com

## 安装

Swift Package Manager:在 Xcode 里 File → Add Package,填本仓地址。

## 最小接入

```swift
import HecongChatSDK

// APP 启动时(用户已同意隐私政策后):只登记参数,零联网
HecongChat.shared.configure(HecongChatConfig(channelId: "你的渠道ID"))

// 打开客服
let chat = HecongChatViewController(config: HecongChatConfig(channelId: "你的渠道ID"))
navigationController?.pushViewController(chat, animated: true)
```

---

> ⚠️ **本仓是分发产物,由上游仓库单向同步生成** —— 请不要直接在这里改代码,改动会在下次
> 同步时被覆盖。问题与需求请走 support@aihecong.com。
