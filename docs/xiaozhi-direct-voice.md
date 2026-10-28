# 小智直接连接小冠

这一阶段把 Mac 桥接里的语音流程移到 iPhone：小智通过 Wi-Fi 将 Opus
发给小冠，小冠使用手机已配置的语音识别、Agent 和回复音色，再将 Opus
送回小智播放。正常使用不需要运行 Mac 桥接，也不需要打开 Debug RPC。
ESP32-C3 固件无需改动。

## 使用

1. 小智和 iPhone 连接同一个 Wi-Fi。
2. 小冠「设置 → 小智设备」打开「连接小智设备」。第一次使用系统识别时，
   允许语音识别权限；同时允许小冠访问本地网络。
3. 复制页面的配网地址，在小智配网页的 OTA 地址中填写并保存。这个接口
   仅返回连接配置，不返回固件下载信息。保留之前的地址以便回退。
4. iPhone 回到家庭 Wi-Fi，保持小冠在前台。开关打开期间屏幕保持唤醒。
5. 小智就绪后按 OK，说话并停顿，回复从小智播放。设备页显示状态、最近
   一轮文字和已完成轮数，也能打开专用会话。

连接开关在 App 冷启动时默认关闭。切到后台会暂停服务，回到前台时，如果
开关仍然打开，会重新监听。手机 Wi-Fi IP 改变后，需要更新设备的配网地址。
目前验证范围是家庭 Wi-Fi，个人热点、锁屏和后台常驻不属于本阶段。

「开始一段新对话」保留旧会话，下一轮创建新会话。「解除设备配对」更新
设备凭据，旧配网地址失效；需要重新配置。配对和会话标识保留在手机本地，
配对密钥使用设备专属 Keychain，不通过 iCloud 同步。

## 接口与边界

- HTTP 8765：`GET /health` 返回服务名、绑定和连接状态；带随机令牌的
  `GET/POST /ota/<token>` 首次绑定设备 MAC，返回 WebSocket 配置。
- WebSocket 8766：系统 Network.framework 负责握手、消息边界与 ping。
  验证 `Device-Id`、`Protocol-Version: 1` 和 `Authorization: Bearer …`。
  同时仅允许一台设备连接，消息上限 8 KiB。
- 收音是 16 kHz、单声道、60 ms Opus；系统 AudioConverter 编解码，现有
  Silero VAD 分段，单次语音最多 20 秒。编码和 VAD 不占用主线程。
- 识别和合成复用 VoiceProviderResolver，支持手机所选供应商；具体供应商
  的可用性仍取决于用户配置。本阶段不修改这些配置。
- 专用会话通过 `submitProgrammaticPrompt(origin: .device)` 提交，保留
  输入框草稿；会话忙、压缩中或有待发内容时拒绝。只取本次用户消息后的
  回复，手机不会同时朗读设备回复。会话锁和 App 锁仍生效。
- 打断或断线使正在生成的播放失效，不撤销已经提交的 Agent 操作；在实际
  任务结束前维持串行限制。断线、识别失败和超时都不自动重发。
- 回复朗读最多 500 字、90 秒，按 60 ms 发送音频，完整文字保留在手机会话。
  不支持同时收音和播放、设备 MCP 工具或原小智云端人设的自动迁移。
- HTTP/WebSocket 适用于可信家庭局域网，不对公网开放；随机配网地址包含
  配对凭据，不应发布到 Git 或公开日志。没有设备 shell、文件访问或配置模型
  密钥的接口；设备说的话由小冠现有 Agent 权限和确认流程处理。

## 验证

2026-10-28：签名 iPhoneOS Debug 构建通过，校验原 App Group 和 development
push entitlement 后原位安装到已配对 iPhone，未卸载应用。

模拟小智直接连接真实 iPhone 的一轮测试通过：手机识别「这是连接测试，
不要调用工具，请只回答手机直连正常」，Agent 回复「手机直连正常」，手机
合成并返回 2.34 秒可由 libopus 解码的音频。输入开始至接收结束 17.76 秒，
包含约 6 秒输入及尾部静音，不是固定延迟指标。测试全程没有经过 Mac 桥接
或 Debug RPC。

实体小智首测显示「Connection failed」「检查新版本失败」。当时手机配置
端口不可达，恢复小冠前台后端口和连接开关正常。保持前台、重启小智复测，
用户反馈「可以了」。手机专用会话可见新一轮设备输入「你是谁？」与回复
「我是小冠，你的 AI 助手，很高兴和你聊天。」；该时段 Mac 桥接已经停止。
实体基本交互获得用户确认，持续多轮、按键打断、网络切换及长时间运行仍
未逐项验收。不能将这次成功解释成支持后台或锁屏运行。

在 macOS 上使用平台实现验证协议、配对与音频，需允许系统音频服务：

```sh
swiftc -parse-as-library \
  src/ios/Devices/Xiaozhi/XiaozhiProtocol.swift \
  src/ios/Devices/Xiaozhi/XiaozhiAudioCodec.swift \
  src/ios/Devices/Xiaozhi/XiaozhiPairing.swift \
  src/ios/Devices/Xiaozhi/XiaozhiLANServer.swift \
  scripts/test_xiaozhi_core.swift -o /tmp/test-xiaozhi-core
/tmp/test-xiaozhi-core
```

24 项检查包含 HTTP 长度/重复头拒绝、配对保存失败、设备身份验证、Opus
帧格式和 3 秒音频往返。Core Audio 第一包裁掉的 40 个样本补为静音；后续
包严格验证 960 个样本。WAV 转换显式检查文件末尾，避免越过 EOF 读取。

网络测试用合成凭据，不访问真实 Keychain 或模型。在两个终端分别运行：

```sh
/tmp/test-xiaozhi-core --serve
python3 scripts/test_xiaozhi_lan.py  # 需要 aiohttp
```

已通过配对/认证、文本和二进制、ping、连接互斥、重连、超大消息拒绝检查。
真实手机的软件链路使用 xiaozhi 仓库的 `bridge/direct_voice_smoke.py`，其
测试音频直接发给 iPhone，Mac 只扮演设备，不承担识别、Agent 或回复合成。

安装应使用 `scripts/build_install_ios.sh`，保留原 App Group、签名和推送
权限校验。不能通过移除 entitlements 来绕过安装错误。
