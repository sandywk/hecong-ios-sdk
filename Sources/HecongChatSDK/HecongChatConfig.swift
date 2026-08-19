// 壳配置 + 宿主回调协议。
//
// 公共面 ObjC 可调是硬要求(app-sdk-plan.md §8.1:老项目租户仍大量 ObjC)——
// 所以这里是 NSObject 子类 + @objc 协议 + 字符串档位,不用 Swift-only struct / 枚举关联值。

import Foundation

/// 壳式 app-sdk 配置。国内合规注意(app-sdk-plan.md §7.3 延迟初始化):
/// 本类只是参数容器,零活动;网络/存储访问从 `HecongChatViewController` 装载才开始,
/// 接入方应在用户同意隐私政策后再创建/展示 VC。
///
/// 装载形态(2026-08-17 改版):壳内本地骨架页 + 静态域拉插座 —— 租户只需渠道 ID,
/// **零域名接入**(不再需要对话链接 URL;原因链见 HecongLocalSchemeHandler 头注释)。
@objc(HecongChatConfig)
public final class HecongChatConfig: NSObject {
  /// APP 渠道 ID(工作台渠道页复制)—— 唯一必填项
  @objc public let channelId: String

  /// 插座 JS 地址(默认线上静态域固定路径;仅 SDK 开发本地联调需要覆盖,租户不动)
  @objc public var loaderUrl: String = HecongBridgeConstants.defaultLoaderUrl

  /// 骨架页附加 query(高级/演示用:如 ["hh": "0"] 用 H5 自带标题栏、["lang": "en"] 指定语言;
  /// 缺省时壳自动带 hh=1 —— APP 有原生导航,H5 不画标题栏)
  @objc public var extraQuery: [String: String] = [:]

  /// 指派技能组(**启动档**;`sdk-agent-routing.md` / `app-sdk-plan.md §10.7`)。
  ///
  /// 租户平台自己算好了"这个客户该由谁接待"时用它 —— 值会拼进骨架页 query(`?sg=/fb=/fbg=`),
  /// 走 H5 既有的 URL 解析链。**聊天页开着时要换组**用 `HecongChat.shared.setRouting(...)`。
  @objc public var routing: HecongRouting?

  /// 深浅色四档(**默认 `host`:聊天页自动跟随你的 APP,零代码**):
  ///
  /// - `host`:**默认**。跟随宿主 APP 当前深浅色(读 traitCollection),APP 切换时实时同步
  /// - `light` / `dark`:宿主显式指定,压过渠道后台配置
  /// - `auto`:渠道后台说了算(工作台配 light/dark 即生效;配 auto 时 H5 自己跟系统)
  ///
  /// ⚠️ 默认值 2026-08-18 由 `auto` 改为 `host`:APP 对接的标准形态就是"聊天页跟着 APP 走",
  /// 让接入方零代码即得。**代价**:渠道后台配的深浅色在 APP 端默认不再生效 —— 要后台主导
  /// 就显式配 `auto`。实现上 `host`/`light`/`dark` 都注入具体值(= 三档链第①档"显式声明"),
  /// 只有 `auto` 零注入(web-sdk-theming.md §7.3.1)。
  @objc public var colorScheme: String = "host"

  /// 宿主稳定标识(可选,app-sdk-plan.md §六"设备指纹"档):仅作镜像的**首次种子**;
  /// 已有镜像/H5 已有身份时不会顶掉既有号(桥协议 §二.2 播种规则,这是特性不是缺陷)。
  @objc public var deviceId: String?

  /// 同一 APP 接多个渠道时区分 anonymousId 镜像的 scope(默认共用一份)
  @objc public var anonymousIdScope: String?

  /// 错误上报开关(app-sdk-plan.md §10.3)。默认开 —— 关了租户报障时我们连链路都拿不到。
  /// 只报**壳自己接住**的失败(装载/桥/HTTP/权限),不装任何全局崩溃钩子(不碰宿主的 Bugly/
  /// Crashlytics),不发聊天内容/会员资料/匿名号(§10.3 隐私四条)。
  @objc public var errorReportingEnabled: Bool = true

  /// 未读轮询间隔(秒;仅 `HecongChat.startUnreadTracking()` 显式开启后生效)。
  /// 下限 30s,内部强制(防配出高频请求)。未读能力**默认关闭**,详 app-sdk-plan.md §10.2。
  @objc public var unreadPollInterval: TimeInterval = 60

  @objc public init(channelId: String) {
    self.channelId = channelId
    super.init()
  }
}

/// 指派技能组的取值(`sdk-agent-routing.md §3.1`)。
///
/// **用组名不用 ID** 是规划的既定决策(租户零配置接入,代码可读);组名允许中文,
/// 壳会自动 URL 编码。降级策略缺省 = `normal`(找不到该组时走正常轮询)。
@objc(HecongRouting)
public final class HecongRouting: NSObject {
  /// 技能组名称(工作台里那个名字,允许中文)
  @objc public let skillGroup: String
  /// 找不到 / 无人在线时怎么办:`group`(转兜底组,须给 fallbackGroup) / `normal` / `leave_message`
  @objc public var fallback: String?
  /// `fallback == "group"` 时的兜底组名
  @objc public var fallbackGroup: String?

  @objc public init(skillGroup: String) {
    self.skillGroup = skillGroup
    super.init()
  }

  @objc public convenience init(skillGroup: String, fallback: String?, fallbackGroup: String?) {
    self.init(skillGroup: skillGroup)
    self.fallback = fallback
    self.fallbackGroup = fallbackGroup
  }

  /// 桥命令 payload(`setRouting`);URL 档另走 query,两处形状刻意一致便于对照
  func payload() -> [String: Any] {
    var out: [String: Any] = ["skillGroup": skillGroup]
    if let fallback = fallback { out["fallback"] = fallback }
    if let fallbackGroup = fallbackGroup { out["fallbackGroup"] = fallbackGroup }
    return out
  }
}

/// 壳 → 宿主 APP 的事件回调(全部可选;不实现即走壳内默认行为)。
@objc(HecongChatDelegate)
public protocol HecongChatDelegate: AnyObject {
  /// H5 装配完成,身份命令已可发(在此之前调 identify 会自动排队,ready 后补发)
  @objc optional func hecongChatReady()

  /// 未读数变化 → 更新 APP 角标 / tab 红点(壳已声明 'badge' capability)
  @objc optional func hecongChatUnreadDidChange(_ count: Int)

  /// 身份绑定成功 / 登出完成(同步 native 侧登录态展示)
  @objc optional func hecongChatDidIdentify(_ userId: String)
  @objc optional func hecongChatDidResetUser()

  /// 消息内外链被点。返回 true = 宿主自行处理(内开浏览器页等);false / 未实现 = 壳跳系统浏览器
  @objc optional func hecongChat(handleOpenUrl url: URL) -> Bool

  /// 附件下载请求。返回 true = 宿主自行处理;false / 未实现 = 壳跳系统浏览器(Safari 下载)
  @objc optional func hecongChat(handleDownload url: URL, filename: String?) -> Bool

  /// H5 标题栏关闭键被点(壳声明 'close' capability 后 H5 才画)。返回 true = 宿主自行处理
  /// 退出;false / 未实现 = 壳默认退出(present 形态 dismiss,push 形态 pop)
  @objc optional func hecongChatDidRequestClose() -> Bool

  /// 生效匿名号变化(推送闭环必接,app-sdk-plan.md §10.5)。
  ///
  /// 用途:未登录访客的离线推送 —— 后端 webhook 回调带的就是这个号,租户需把它与自己的
  /// 推送 token 一起报到自家后端才推得出去。
  /// ⚠️ **不要假设它等于 `config.deviceId`**:H5 可能 adopt 后端下发的档案匿名号
  /// (桥协议 §二.2 第 2 条),一律以本回调的值为准。
  @objc optional func hecongChatDidChangeAnonymousId(_ anonymousId: String)

  /// 自定义按钮被点(`HecongChat.registerAction` 注册的那些;桥协议 §四 `action-click`)。
  ///
  /// 典型用法 —— 商品/订单选择器(`sdk-public-api-contract.md §九`):
  /// 收到回调 → 现取自家商品列表 → `setPickerData("product", items)` → `openPicker("product")`,
  /// 访客点中一条即作为卡片消息发给客服。**数据现取而不是提前灌**:列表常随登录态/库存变化。
  @objc optional func hecongChat(didClickAction id: String)

  /// 页面加载失败(断网 / 静态域不可达)。壳已画内置兜底页 + 重试按钮;本回调供宿主
  /// 上报自家监控或换成自己的兜底 UI(换 UI 时自行盖住聊天视图,壳不感知)。
  @objc optional func hecongChatDidFailToLoad(_ reason: String)

  /// 标题栏身份变化 —— **宿主自绘标题栏用**(owner 2026-08-18)。
  ///
  /// 很多 APP 会自己画顶栏(左边原生返回键,右边头像/昵称/签名),这份数据只有 WebView 里有,
  /// 宿主自己拿不到;而且它**会变**:会话前是渠道身份 → 接待后是客服/机器人 → 转接再变一次。
  /// 照这几个字段画,就与 SDK 标题栏完全一致(同一出口同一时刻的同一份值)。
  ///
  /// ⚠️ 别拿"谁在接待"去画标题栏 —— 排队中/会话前没人接待,那样会画出一片空白。
  /// ⚠️ `pending` 为真时 SDK 正画骨架占位,宿主也该占位,否则会先空一下再跳出名字。
  @objc optional func hecongChatHeaderIdentityDidChange(_ identity: HecongHeaderIdentity)

  // MARK: - 会话事件(capability 'session-events',契约 §六 APP 列)

  /// **通吃回调 —— 会话事件的完整入口**(H5 发来的每一条会话事件都经这里,一条不漏)。
  ///
  /// 🔴 **这是本 SDK 面向未来的扩展点,优先接它**:H5 侧将来新增的会话事件,
  /// **不需要你升级 SDK、我们也不需要发原生包**,直接就能从这里收到 —— 原生包的更新率
  /// 远低于 H5(桥协议 §一 硬前提 3),具名回调那条路每加一个事件都要等全网 APP 升级。
  ///
  /// 下面那几个具名回调只是**常用事件的便利糖**(有类型、不用解字典),
  /// 它们能收到的,这里同样会收到一份。两者都接的话同一件事会处理两次,自己二选一。
  ///
  /// - Parameters:
  ///   - name: 事件名,与网页版 `hc.on(name, ...)` 完全同名(契约 §六),如 "message:incoming"
  ///   - payload: 事件数据;无数据的事件(如 network:*)为 nil。字段含义见契约 §六
  @objc optional func hecongChat(didReceiveEvent name: String, payload: [String: Any]?)

  /// 收到**对方**消息(客服 / 机器人 / 系统)—— 弹本地通知、震动、红点常用这个
  @objc optional func hecongChat(didReceiveIncomingMessage message: HecongMessage)

  /// 收到任意消息(含访客自己发出并送达的);只想要对方消息用 `didReceiveIncomingMessage`
  @objc optional func hecongChat(didReceiveMessage message: HecongMessage)

  /// 新对话创建(埋点"发起了咨询")
  @objc optional func hecongChatConversationDidStart(_ conversationId: String)

  /// 对话结束(客服关闭 / 超时归档);拿不到 id 时为 nil
  @objc optional func hecongChatConversationDidEnd(_ conversationId: String?)

  /// 与服务端的连接通断 —— 宿主想显示"连接中断"时接它
  @objc optional func hecongChatNetworkDidChange(_ online: Bool)
}

/// 标题栏身份(桥协议 §四 header-identity)。字段可选 —— 渠道没配签名/头像就是没有,
/// 宿主按"有就画,没有就不画"处理(双向兼容:新增字段老壳无视)。
@objc(HecongHeaderIdentity)
public final class HecongHeaderIdentity: NSObject {
  @objc public let nickname: String?
  @objc public let avatar: String?
  @objc public let signature: String?
  /// 这份身份是谁的:"agent" / "bot" / "channel"(渠道兜底) / nil(无身份)
  @objc public let source: String?
  /// true = SDK 在画骨架占位(身份还在解析),宿主也该占位而不是留白
  @objc public let pending: Bool

  init(nickname: String?, avatar: String?, signature: String?, source: String?, pending: Bool) {
    self.nickname = nickname
    self.avatar = avatar
    self.signature = signature
    self.source = source
    self.pending = pending
    super.init()
  }
}
