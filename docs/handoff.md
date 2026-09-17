# 接手文档

更新于 2026-09-17。

## 现在的状态
- 设计已定，文档已写完：`CONTEXT.md`、`docs/spec.md`、`docs/protocol.md`、`docs/adr/0001`–`0006`
- 已 `git init`，尚未提交
- **Windows 接收端已实现并用假手机脚本联调通过**：证书/指纹/safeStorage 私钥、TLS 1.3 服务、分帧协议、配对二维码（5 分钟一次性）、mDNS、hello 鉴权（notPaired/busy/versionMismatch/receiverLocked）、心跳+10 秒重连宽限、投屏窗口（WebCodecs+SPS 改写+PCM 播放+控制条+断线浮层）、主窗口（二维码/设备列表/设置/导出日志）、托盘+关窗入托盘+开机自启
- **Android 端已实现并通过 `assembleDebug`**：扫码配对（CameraX+ML Kit）、Keystore 加密 token、NSD 发现、TLS 指纹固定、MediaProjection+MediaCodec H.264+AudioPlaybackCapture 48k s16le、分帧发送+拥塞丢帧降码率、心跳+10 秒重连、旋转重建编码器、前台服务+停止通知
- **真机联调还没做过**（手机 ↔ 电脑端到端）。验收清单见下文"待真机验证"和 `docs/spec.md` 第 7 节
- **M2 已实现（Android 端代码完成、`assembleDebug` 通过；接收端旋转闭环已本地验证）**：GL 裁剪管线、内容区域检测、重力转正、强制旋转循环、通知栏快捷按钮、音量归零/恢复、变暗不熄屏、导出日志、控制条旋转按钮
- 下一步：真机测 M1+M2 → 修 bug → M3（iOS 27+）

## M2 实现要点（2026-09-17）

- `GlPipe.kt`：VD → SurfaceTexture(OES) → EGL → 编码器输入 Surface；裁剪 = 纹理坐标取子矩形；每 20 帧渲染一份 96×54 读回给黑边分析
- `ContentDetect.kt`：逐行/列统计"点亮比例"（>12% 才算内容列），整帧均值过低视为暗场返回 null 保持现状
- `MirrorService`：`appliedCrop` 稳定 3 个采样（~1s）才重建编码器（编码分辨率=内容区域原始像素，ADR 0004）；`forcedCycle` 0→1→2→3→0 循环；重力转正 = 竖屏界面 + 横拿≥1s（z 主导平放不算）+ 流里还有黑边；通知栏按钮=旋转/截取开关/停止；`SCREEN_DIM_WAKE_LOCK`（已弃用但功能符合"变暗不熄屏"）；`STREAM_MUSIC` 归零并在结束时恢复
- 接收端：`rotation` 字段早就在 `drawFrame` 里旋转 canvas；新增 `btnRot` → `command:rotate` → 手机端推进循环（两端同一状态源在手机）
- fake-sender：`--rotate N` 静态旋转 / `--rotateEvery s` 周期轮转；收到 `command:rotate` 自动轮转
- 已验证（本地）：旋转按钮 → `command:rotate` → rotation 字段变化 → canvas 宽高互换（960×540↔540×960）
- 待真机：GL 管线性能/耗电、黑边阈值在真实内容下的表现、重力转正方向是否反了（ax 符号→rotation 映射如反了改 `rotationField()` 里 1/3 对调）、音量归零后采集音量是否仍满、SCREEN_DIM 在国产 ROM 的行为

## 先读这些（按顺序）
1. `CONTEXT.md`：术语
2. `docs/spec.md`：产品行为、已知限制、里程碑
3. `docs/protocol.md`：协议
4. `docs/adr/`：为什么这样选

## 和用户协作
- 用中文交流
- 代码主要由 AI 写，用户负责运行和真机测试：每一步都给能直接运行的命令和明确的验收动作
- spec 里标"默认，待确认"的几条，开工前先跟用户确认
- 提交、推送前先问用户

## 开发环境（2026-09-17 在用户的 Windows 电脑上查过）
- Node v24.19.0、npm、pnpm、git
- JDK 17（Microsoft OpenJDK 17.0.20.1）
- Android SDK：`C:\Users\xie_f\AppData\Local\Android\Sdk`（含 adb），`ANDROID_HOME` 已设置
- 没有全局 Gradle，也没有 Android Studio：用 Gradle Wrapper 命令行构建
- iOS：用户有 Mac，没有付费 Apple 开发者账号（先用免费账号）；ScreenCaptureKit 的 iOS 路线需要 Xcode 27

## 建议目录
- `windows/`：Electron + TypeScript
- `android/`：Kotlin + Gradle
- `ios/`：Xcode 工程（App、录屏扩展、实时活动）
- `docs/`

## 运行方式

### Windows 接收端（`windows/`，pnpm）
```powershell
cd windows
pnpm install        # 首次；pnpm-workspace.yaml 已允许 esbuild/electron 的构建脚本
pnpm dev            # 开发模式（注意：ELECTRON_RUN_AS_NODE 不能设为 1）
pnpm typecheck      # tsc 两套（node + web）
pnpm build          # electron-vite 生产构建到 out/
```
- 数据目录：`%APPDATA%\mp2tv-windows\`（identity.json、store.json、logs/mp2tv.log）
- 启动后日志里有 `pairing qr: mp2tv://pair?...`，可直接复制给假手机脚本用
- 已知坑：ELECTRON_RUN_AS_NODE=1 时 Electron 按 Node 启动、app 为 undefined；`safeStorage.encryptString` 返回 Buffer，JSON 序列化要 `.toString('base64')`（已修，旧格式兼容读取）

### 假手机联调（`tools/fake-sender.mjs`）
```powershell
# 生成测试素材（已生成 test.h264 / test.pcm）
ffmpeg -f lavfi -i testsrc2=size=960x540:rate=30 -t 20 -c:v libx264 -bf 0 -tune zerolatency -pix_fmt yuv420p -f h264 tools/test.h264
ffmpeg -f lavfi -i sine=frequency=440 -t 20 -f s16le -ac 2 -ar 48000 tools/test.pcm

node tools/fake-sender.mjs pair --qr "mp2tv://pair?..."   # 配对，存 tools/fake-device.json
node tools/fake-sender.mjs stream                        # 推流
node tools/fake-sender.mjs unpair                        # 解除配对
# 第二台假手机：--device fake-device2.json --name 名字
```
已验证（2026-09-17 生产构建 `out/`）：配对、投屏画面渲染（WebCodecs `avc1.64001f` 硬解，首帧即解码成功，截图确认 testsrc2 测试图）、PCM 音频无 `Int16Array` 对齐错误、`busy`/`notPaired`/`receiverLocked` 拒绝、同名手机重连接管、10 秒重连宽限超时、锁屏期间 rAF 暂停属正常。

验证中修复的 bug：
- 音频帧头是 8 字节（`[pts u64]+PCM`），fake-sender 和 mirror 曾一致错用 9 字节偏移互相掩盖；Android 端一直按规范发 8 字节
- `Int16Array` 要求 byteOffset 按 2 对齐，`Uint8Array.subarray` 偏移可能为奇数 → 先拷贝到对齐 buffer
- `session:start` 曾挂在 `did-finish-load`，IPC 会晚于 `mirror:ready` 触发的 backlog flush 到达，把刚配置好的解码器 reset 掉 → 改为在 `mirror:ready` handler 里先发 `session:start` 再 flush backlog，保证顺序

### Android（`android/`，Gradle Wrapper）
```powershell
cd android
.\gradlew assembleDebug    # 产物 app\build\outputs\apk\debug\app-debug.apk
adb install app\build\outputs\apk\debug\app-debug.apk
```
- AGP 8.13.2 + Gradle 8.14.3 + Kotlin 2.2.21，JDK 17，compileSdk 36 / targetSdk 35 / minSdk 29
- 依赖：androidx.activity、CameraX 1.4.2、ML Kit barcode 17.3.0（均非 GPL）
- UI 全部代码手写（无 Compose/AppCompat）；App 图标复用了 windows/assets/icon.png

## 待真机验证（按影响排序）
1. **端到端**：手机扫码配对 → 点设备投屏 → 画面/声音/延迟 100–200ms
2. WebCodecs 硬解改写 SPS 后是否还攒帧（假手机流已看到画面，真机编码器 SPS 可能不同）；不行就改 `prefer-software`
3. Windows 上 Node 的 mDNS 和系统自带 mDNS 共用 5353 端口，手机能否稳定发现电脑（假手机用的是直连 IP，没走 NSD）
4. Android：媒体音量调 0 后录到的声音是否仍是满音量（AOSP 源码推断，各厂商 ROM 可能不同）；Android 17 在后台恢复音量是否被系统忽略
5. Android："变暗不熄屏"唤醒锁（`SCREEN_DIM_WAKE_LOCK` 已弃用）在国产 ROM 上是否有效、一碰是否立即变亮
6. iOS 27 ScreenCaptureKit：锁屏行为、帧方向信息、后台能否读重力传感器、调低音量是否影响录到的声音
7. iOS 旧路线：`RPVideoSampleOrientationKey` 跟随界面还是重力；扩展里能否读重力传感器；免费账号能否用 App Groups；约 50MB 内存上限
8. 实时活动按钮（`LiveActivityIntent` 在 App 进程执行）转发给录屏扩展（App Groups + Darwin 通知）是否可靠

## M1 代码端还没验证的项
- ~~锁屏拒绝（`receiverLocked`）~~：已验证，锁屏时 hello 返回 `{ok:false, reason:'receiverLocked'}`
- ~~投屏窗口交互~~：已验证——经 CDP（`--remote-debugging-port=9223`）驱动 DOM 点过全部按钮：静音双向切换、置顶开/关、全屏/窗口切换、Esc 退全屏、双击进全屏、控制条 mousemove 唤醒 + 3s 自动隐藏、退出投屏关闭窗口且对端收到 `stop`
- 二维码 5 分钟过期、一次性使用（轮换逻辑已测，完整 5 分钟过期未等满）
- Android 端一切真机行为：扫码、NSD、投影授权、编码器 Annex B 输出、音频采集、旋转重建

## 选库注意
- 只用非 GPL 许可的库（用户要求）
- Node 没有生成 X.509 证书的内置 API，需要选库；mDNS、二维码生成和扫描也一样

## 待真机验证（按影响排序）
1. WebCodecs 硬解改写 SPS 后是否还攒帧；不行就改 `prefer-software`
2. Windows 上 Node 的 mDNS 和系统自带 mDNS 共用 5353 端口，手机能否稳定发现电脑
3. Android：媒体音量调 0 后录到的声音是否仍是满音量（AOSP 源码推断，各厂商 ROM 可能不同）；Android 17 在后台恢复音量是否被系统忽略
4. Android："变暗不熄屏"唤醒锁（`SCREEN_DIM_WAKE_LOCK` 已弃用）在国产 ROM 上是否有效、一碰是否立即变亮
5. iOS 27 ScreenCaptureKit：锁屏行为、帧方向信息、后台能否读重力传感器、调低音量是否影响录到的声音
6. iOS 旧路线：`RPVideoSampleOrientationKey` 跟随界面还是重力；扩展里能否读重力传感器；免费账号能否用 App Groups；约 50MB 内存上限
7. 实时活动按钮（`LiveActivityIntent` 在 App 进程执行）转发给录屏扩展（App Groups + Darwin 通知）是否可靠

## 事实核查记录

直接核对过 Apple 官方文档：
- ScreenCaptureKit 在 iOS 27 可用：App 内采集、`screen-capture` 后台模式、经 `SCContentSharingPicker` 授权，需要 Xcode 27 — https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios
- `SCStreamConfiguration.capturesAudio` 从 iOS 27.0 起可用 — https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- `RPBroadcastSampleHandler` 在 iOS 27.0 标记弃用 — https://developer.apple.com/documentation/replaykit/rpbroadcastsamplehandler
- 免费账号：最多 10 个 App ID、3 台设备、每台 3 个 App，7 天过期 — https://developer.apple.com/support/compare-memberships/

调研代理汇总（未逐条复核）：
- 录屏扩展共享主 App 的本地网络权限 — https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- `LiveActivityIntent.perform` 在 App 进程执行 — https://developer.apple.com/documentation/appintents/liveactivityintent
- Android 14+：每次投屏都要授权、`createConfigForDefaultDisplay()`、`onCapturedContentResize` — https://developer.android.com/media/grow/media-projection
- Android 15：投屏时隐藏敏感通知；QPR1 起锁屏自动停止投屏 — https://developer.android.com/about/versions/15/behavior-changes-all
- Android 17：`MediaProjectionConfig.Builder`；后台调音量受限 — https://developer.android.com/sdk/api_diff/37/changes/android.media.projection.MediaProjectionConfig 、https://developer.android.com/about/versions/17/changes/bg-audio
- Android 录到的播放声音不受媒体音量影响（源码推断）— https://android.googlesource.com/platform/frameworks/av/+/main/services/audiopolicy/common/managerdefinitions/src/AudioOutputDescriptor.cpp 、https://github.com/Genymobile/scrcpy/pull/5102
- iOS ReplayKit 的 App 声音格式（旧版本实测）— https://github.com/twilio/video-quickstart-ios/pull/419/files
- WebCodecs：无 description 时按 Annex B；SPS 没声明 `max_num_reorder_frames` 会攒帧 — https://w3c.github.io/webcodecs/avc_codec_registration.html 、https://chromium.googlesource.com/chromium/src/+/main/media/gpu/h264_decoder.cc 、https://github.com/MicrosoftEdge/WebView2Feedback/issues/4099
- Electron 当前稳定版 44.4.1（Chromium 152）— https://releases.electronjs.org/

## M3 状态（iOS 27+ 发送端，2026-XX-XX）

代码已写完，**未编译**（本机无 macOS/Xcode）。需在 Mac 上验证。

### 结构

- `ios/project.yml` — XcodeGen 工程定义：`mp2tv`（App，deploymentTarget 17.0）+ `Mp2tvActivity`（WidgetKit 扩展）。`cd ios && xcodegen` 生成 `mp2tv.xcodeproj`
- `ios/mp2tv/` — App 源码：
  - `Proto.swift` 分帧/`Net.swift` TLS+指纹固定/`Store.swift` Keychain+UserDefaults/`Discovery.swift` NWBrowser mDNS
  - `Engine.swift` 会话状态机（idle/pairing/connecting/streaming/reconnecting），配对、hello、10s 重连窗、`command` 处理、`protectedDataWillBecomeUnavailable` 锁屏停止
  - `Capture.swift`（iOS 27 限定）`SCContentSharingPicker` → `SCStream` → `VTCompressionSession` → Annex B；CIImage 裁剪；`capturesAudio` → `AVAudioConverter` → 48k s16le stereo；每 20 帧回读 96×54 亮度图给截取检测
  - `ContentDetect.swift` Android 同名算法移植（阈值一致）、`Rotation.swift` 强制循环 + 重力转正（CMMotionManager）
  - `LiveAct.swift` 实时活动管理、`Log.swift` 文件日志
  - `App.swift`/`ContentView.swift`/`ScanView.swift` SwiftUI（列表、扫码、设置、导出日志）
- `ios/shared/` — App 与扩展共用：`ActivityAttributes.swift`、`Intents.swift`（`LiveActivityIntent`→App 进程执行，免费账号无需 App Groups）、`CmdBus.swift`（解耦扩展对 Engine 的引用）
- `ios/activity/` — Widget 扩展：锁屏卡片 + 灵动岛，三个按钮

### 实现决策

- `Capture`/`PickerObs` 是 iOS 27 限定类型，Engine 用 `AnyObject` 擦除 + `@available` 计算属性持有，App 本身仍可在 iOS 17–26 跑配对/UI（为 M4 ReplayKit 留位）
- token 存 Keychain（`WhenUnlockedThisDeviceOnly`），hello 时转 base64url 发送
- 接收端 `command` 的字段名是 `action`（不是 `cmd`），值 `rotate`/`keyframe`
- 停止时先发 `{t:'stop',reason:'user'}` 延迟 150ms 再关 socket，避免 cancel 丢帧

### 待 Mac/真机验证（预期有编译错，逐个修）

1. `SCContentSharingPicker.shared.present()`/observer 方法签名是否与 Xcode 27 SDK 一致
2. `VTCompressionSession` C 回调、`CMVideoFormatDescriptionGetH264ParameterSetAtIndex` 签名
3. `UIApplication.protectedDataWillBecomeUnavailable` 是否真在手动锁屏时触发（需设备设密码，数据保护开启）
4. SCK 后台采集时 `CMMotionManager` 是否可读、`interfaceOrientation` 轮询是否有效
5. Widget 扩展能否直接编译 `shared/`（LiveActivityIntent 在扩展 target 的可用性）
6. 免费账号：App Groups 不用了，但实时活动本身免费账号是否可用待确认
