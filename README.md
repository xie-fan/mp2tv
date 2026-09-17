# mp2tv

手机（Android / iOS）在同一局域网内把**屏幕画面和声音**投到 Windows 电脑上的个人/家庭投屏软件。

不依赖系统投屏协议（Miracast / AirPlay / DLNA），自研发送端 App + 接收端 App，走自定义 TCP/TLS 协议，目标是跨平台一致的体验和可控的画质/延迟。

## 特性

- **扫码配对**：电脑端主窗口显示一次性二维码，手机扫码即完成配对，凭据长期保存，之后免扫码直接投屏
- **TLS 加密 + 证书指纹固定**：配对时手机记录电脑证书指纹，之后每次连接校验，防局域网中间人
- **画面 + 声音同传**：H.264 视频 + 48kHz PCM 立体声，走同一条 TLS 连接
- **全屏/窗口两种模式**：投屏默认全屏无边框，可切到可拖动、可缩放、可置顶的窗口
- **控制条**：移动鼠标浮现，支持静音、全屏/窗口切换、置顶、退出投屏；3 秒无操作自动隐藏
- **自动重连**：断线后 10 秒宽限期内重连可恢复会话，画面不重开
- **会话互斥**：一台电脑同一时刻只接受一台手机投屏，第二台会被礼貌拒绝
- **锁屏保护**：电脑锁屏时拒绝新的投屏请求

## 项目结构

```
mp2tv/
├── windows/          # 电脑端：Electron + TypeScript
│   ├── src/main/     #   主进程：TLS 服务、配对、mDNS、会话状态机、托盘
│   ├── src/preload/  #   预加载桥
│   └── src/renderer/ #   渲染层：主窗口 UI + 投屏窗口（WebCodecs 解码）
├── android/          # 手机端：Kotlin + Gradle Wrapper
│   └── app/src/main/ #   扫码配对、NSD 发现、MediaProjection 编码发送
├── tools/
│   └── fake-sender.mjs  # 假手机联调脚本（无真机也能测接收端）
├── docs/
│   ├── spec.md       # 产品规格
│   ├── protocol.md   # 协议规范
│   ├── handoff.md    # 开发交接/验证记录
│   └── adr/          # 架构决策记录（6 篇）
└── CONTEXT.md        # 领域术语表
```

## 技术栈

| 端 | 技术 |
|---|---|
| 电脑端 | Electron 44, TypeScript, electron-vite, WebCodecs（H.264 硬解）, AudioWorklet（PCM 播放）, Node TLS, bonjour-service（mDNS）, safeStorage（凭据加密） |
| 手机端 | Kotlin, Android API 29+, CameraX + ML Kit（扫码）, Android Keystore（token 加密）, NSD（服务发现）, MediaProjection + MediaCodec（采集编码）, AudioPlaybackCapture（系统声音） |

## 协议概览

一条 TLS TCP 连接复用三种帧（详见 `docs/protocol.md`）：

```
[type: u8][length: u32 BE][payload]        # payload ≤ 8 MiB

type=1  控制帧：UTF-8 JSON（hello / ping / stop / ...）
type=2  视频帧：[pts: u64 µs][flags: u8][rotation: u8][H.264 Annex B AU]
type=3  音频帧：[pts: u64 µs][PCM s16le 48kHz stereo]
```

配对流程：手机扫二维码拿到电脑的地址、端口、证书指纹和一次性配对码 → 建立 TLS → 校验指纹 → 交换长期 token。之后投屏用 token + `hello` 握手开始会话。

## 构建与运行

### 环境要求

- Node.js 24+（其他现代版本亦可）
- pnpm（电脑端包管理器）
- JDK 17 + Android SDK（手机端；`compileSdk 36`，无需 Android Studio）
- ffmpeg（可选，用于生成联调测试素材）

### 电脑端（Windows）

```powershell
cd windows
pnpm install
pnpm dev          # 开发模式（热更新）
# 或
pnpm typecheck    # 类型检查
pnpm build        # 生产构建到 out/
npx electron .    # 直接跑生产构建
pnpm dist         # 打绿色版 exe（electron-builder portable，输出到 release/）
```

启动后主窗口显示配对二维码（5 分钟过期自动轮换），同时注册 `_mp2tv._tcp` mDNS 服务供手机发现。

### 手机端（Android）

```powershell
cd android
.\gradlew.bat assembleDebug
adb install app\build\outputs\apk\debug\app-debug.apk
```

手机上打开 mp2tv → 点扫码配对 → 对准电脑端二维码 → 回到列表点电脑名称开始投屏。

需要的权限：相机（扫码）、麦克风（`AudioPlaybackCapture` 要求）、通知（前台服务）、录屏（每次投屏系统弹窗授权）。

> 注意：手机和电脑必须在同一局域网；二维码包含电脑全部 IPv4 地址，手机会逐个尝试。

### 无真机联调（假手机）

`tools/fake-sender.mjs` 是完整的协议实现，可以在没有 Android 手机时测试接收端全链路：

```powershell
# 生成测试素材（960x540 testsrc2 + 48kHz 正弦波）
ffmpeg -f lavfi -i "testsrc2=size=960x540:rate=30" -t 20 -c:v libx264 -f h264 tools/test.h264
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 20 -ac 2 -f s16le tools/test.pcm

node tools/fake-sender.mjs pair --qr "mp2tv://pair?v=1&h=...&p=...&fp=...&c=...&n=..."
node tools/fake-sender.mjs stream --video tools/test.h264 --audio tools/test.pcm --name 假手机
node tools/fake-sender.mjs unpair          # 解除配对

# 多设备测试（测 busy 拒绝）
node tools/fake-sender.mjs --device 2 pair --qr "..."
node tools/fake-sender.mjs --device 2 stream ...
```

二维码 URI 在电脑端日志（`pairing qr: ...`）里可以直接复制。

## 使用说明

投屏中电脑端画面上的操作：

| 操作 | 效果 |
|---|---|
| 移动鼠标 | 底部浮现控制条 |
| 双击画面 | 全屏 ↔ 窗口切换 |
| Esc | 退出全屏到窗口模式 |
| 静音 | 切换声音开关 |
| 置顶 | 窗口模式下窗口始终在最前 |
| 退出投屏 | 结束会话，两端同时停止 |

电脑端主窗口可查看已配对设备列表、删除设备（解除配对）；关闭主窗口最小化到系统托盘继续接收投屏。

## 安全模型

- 配对二维码**一次性**且 5 分钟过期，配对码在 TLS 通道内消费后即失效
- 配对 token 电脑端用 `safeStorage` 加密落盘，手机端用 Android Keystore 加密
- 每次连接校验 TLS 证书指纹，指纹不匹配直接断开
- 任一端解除配对后，对方 token 立即失效（`notPaired`）

## 里程碑

- [x] **M1** Windows 接收端 + Android 发送端（本仓库当前状态）
- [x] **M2** 智能截取（去黑边）、智能旋转（跟随/重力转正/强制旋转）、快捷按钮、音量与亮屏处理 —— 代码完成，待真机验收
- [ ] **M3** iOS 发送端（iOS 17+，ReplayKit 双采集路径）
- [ ] **M4** iOS 旧系统兼容路径

各里程碑的取舍理由见 `docs/adr/`；分版本验收清单见 `docs/testing.md`。

## 验证状态

M1 已通过本地端到端验证（假手机 ↔ 接收端）：配对、持久化、H.264 首帧解码渲染、PCM 音频、控制条全部交互、断线重连、锁屏拒绝、会话冲突（busy）、解除配对（notPaired）。详细验证记录见 `docs/handoff.md`。

尚未验证（需要真实环境）：真机 Android 全链路、不同厂商 MediaCodec 输出差异、mDNS 跨网段发现、iOS 端。

## License

个人项目，暂未指定开源协议。
