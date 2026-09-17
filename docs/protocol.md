# mp2tv 协议 v1

术语见 `CONTEXT.md`，选型原因见 ADR 0002、0005。

## 角色
- 电脑端：TLS 服务端，长期监听
- 手机端：TLS 客户端，配对和投屏时主动连接

## 身份
- 电脑端首次运行生成自签 ECDSA P-256 证书：
  - `fingerprint` = 证书 DER 的 SHA-256
  - `receiverId` = fingerprint 前 8 字节的十六进制
  - 私钥用系统加密存储（Electron `safeStorage`）
- 手机端安装后生成 `senderId`（UUID）
- 配对成功后电脑端生成 `token`（32 字节随机）：手机端存进 Android Keystore / iOS Keychain；电脑端只存 SHA-256(token)

## 发现
- 电脑端监听固定默认端口，被占用时改用随机端口
- mDNS 广播 `_mp2tv._tcp.local`：实例名 = 电脑名；TXT 为 `id=<receiverId>`、`v=1`
- 手机端浏览这个服务，按 `id` 找已配对电脑；发现不了时用上次连接成功的 IP 和端口
- iOS 在 Info.plist 声明 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`（`_mp2tv._tcp`）

## TLS
- TLS 1.3
- 手机端不校验 CA 和主机名，只比对服务端证书的 SHA-256 是否等于已知 fingerprint，不符立即断开

## 分帧
每条消息 = `[type: u8][length: u32 大端][payload]`，length 上限 8 MiB。

- type 1，控制：payload 是 UTF-8 JSON，必有字段 `t`
- type 2，视频：`[pts: u64 大端，微秒][flags: u8，bit0 = 关键帧][rotation: u8，0–3，顺时针 90° 的个数][H.264 Annex B access unit]`
- type 3，声音：`[pts: u64 大端，微秒][PCM s16le，48000Hz，双声道交错]`
- pts 来自手机端单调时钟，视频和声音用同一个时钟

## 配对
二维码内容：
`mp2tv://pair?v=1&h=<ip1>,<ip2>&p=<port>&fp=<fingerprint base64url>&c=<16 字节口令 base64url>&n=<电脑名 URL 编码>`

1. 手机端依次连 `h` 里的地址，按 `fp` 校验证书
2. 手机端 → `{"t":"pair","code":"…","senderId":"…","senderName":"…","platform":"android|ios","v":1}`
3. 电脑端校验口令（5 分钟内、没用过）：
   - 成功 → `{"t":"pairResult","ok":true,"receiverId":"…","receiverName":"…","token":"<base64url>"}`，然后作废口令、刷新二维码、提示"已与 XX 配对"
   - 失败 → `{"t":"pairResult","ok":false,"reason":"codeInvalid|versionMismatch"}`
4. 双方保存已配对设备，关闭连接

## 投屏会话
1. 手机端连接并校验 fingerprint → `{"t":"hello","senderId":"…","token":"…","senderName":"…","v":1}`
2. 电脑端回复 `{"t":"helloResult","ok":true}`，或 `{"t":"helloResult","ok":false,"reason":"…"}`：
   - `notPaired`：令牌不匹配
   - `busy`：正在进行其他手机的投屏会话，附 `"busyWith":"<手机名>"`；同一 `senderId` 不算 busy，直接结束旧会话、接受新连接
   - `versionMismatch`：`v` 不同
   - `receiverLocked`：电脑已锁屏
3. 成功后电脑端进入全屏模式；手机端开始发视频和声音，第一个视频消息必须是带 SPS/PPS 的关键帧
4. 旋转：手机端维护智能旋转状态，每帧的 `rotation` 告诉电脑端显示时顺时针转几个 90°
5. 内容区域变化：手机端重建编码器，发带新 SPS 的关键帧；电脑端发现 SPS 变化就重新配置解码器
6. 电脑端 → 手机端命令：
   - `{"t":"command","action":"rotate"}`：控制条旋转按钮，手机端推进强制旋转循环
   - `{"t":"command","action":"keyframe"}`：电脑端解码出错时请求关键帧
7. 心跳：双方每 2 秒发 `{"t":"ping"}`；6 秒收不到任何消息视为断线
8. 断线：电脑端保持窗口、显示"正在重连"10 秒；手机端 10 秒内用同一 `senderId` 重新 `hello`，发关键帧后继续
9. 结束：任一端发 `{"t":"stop","reason":"user|screenLocked|captureEnded"}` 后关闭连接

## 解除配对
- 手机端删除电脑：电脑在线时连接并发 `{"t":"unpair","senderId":"…","token":"…"}`，电脑端删除记录后关闭连接
- 电脑端删除手机：之后该手机 `hello` 得到 `notPaired`，手机端提示并把这台电脑标为失效

## 媒体参数
- 视频：H.264，不用 B 帧；长边 ≤1920、短边 ≤1080；最高 60fps；关键帧按需发，另外定期发（如每 5 秒）
- 拥塞：手机端发送队列积压时，丢弃非关键帧直到下一个关键帧并下调码率，恢复后慢慢回升
- 电脑端解码：WebCodecs `VideoDecoder`，不传 `description`（按 Annex B）；喂入前检查 SPS，没有 `bitstream_restriction` 或 `max_num_reorder_frames` 不为 0 就改写，否则解码器会攒帧；VideoFrame 用完立即 close
- 声音：Android 用 AudioPlaybackCapture 直接取 48kHz s16le 双声道；iOS 转成同样格式（ReplayKit 的 App 声音常见为 44.1kHz、16bit 大端，要转换）
- 电脑端播放：视频和声音按 pts 统一延迟播放，保证音画同步

## 版本
`v` 是整数，当前为 1；双方不相等即 `versionMismatch`
