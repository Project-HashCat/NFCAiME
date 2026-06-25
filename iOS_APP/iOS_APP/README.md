# iOS_APP

SwiftUI + CoreNFC 源码。提交基线为 Xcode 26 或更高版本，并使用 iOS 26 SDK；
Deployment Target 为 iOS 15，iOS 26 上启用 Liquid Glass，旧系统使用系统按钮样式回退。

在 macOS/Xcode 中打开仓库根目录的 `NFCAime.xcodeproj` 后：

1. 在 Signing & Capabilities 中选择自己的 Apple Developer Team。
2. 按需修改唯一的 Bundle Identifier。
3. 使用支持 NFC 的真机测试；Simulator 无法验证读卡流程。

当前功能：

- 本地/远端服务器模式；本地模式只读卡片基础信息，不连接服务器，也不生成 `#CARD`。
- 远端服务器由用户自行添加 URL 和 RSA 公钥；App 不内置公开服务器地址。
- 远端提交只上传 RSA 加密后的卡片安全数据和认证块，不上传本地计算结果。
- 公开源码不包含 Access Code、Konami Card Number 或官方通讯相关计算逻辑；相关结果由远端服务器返回。
- 网络失败时保留 IDM 和错误状态，便于自建服务器排查。
- 区分地址错误、服务器不可达、超时、HTTP 错误和响应格式错误。
- 保存最近 10 条读卡记录，界面只显示最近 5 条更早记录，并支持复制、分享完整结果。
- 提供连接测试、阶段状态、触觉反馈和多状态 SwiftUI Preview。
