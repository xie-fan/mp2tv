# 一条 TLS over TCP 连接承载控制、视频和声音

只在局域网使用，延迟目标 100–200ms（主要看视频），TCP 足够。所以每个投屏会话只用一条 TLS/TCP 连接，按长度前缀分帧，视频用 H.264 Annex B，声音用 PCM。

## Considered Options

- WebRTC：三端都要引入很重的依赖；在 iOS 录屏扩展约 50MB 的内存上限里风险大；把 App 声音注入 WebRTC 也麻烦。
- 裸 UDP / RTP：要自己做丢包恢复、拥塞控制和加密。

## Consequences

- Wi-Fi 抖动时 TCP 会整体卡住：手机端发送队列积压时要丢非关键帧、降码率。
- PCM 约 1.5Mbps，局域网内可以忽略；以后要压缩再加编码格式。
