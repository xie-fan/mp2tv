# iOS 两条采集路线

iOS 27（2026-09-14 发布）起，ScreenCaptureKit 可以在 iOS 上直接在 App 里录屏和录声音，ReplayKit 的 `RPBroadcastSampleHandler` 同时标记弃用。用户要兼顾升不了 iOS 27 的 iPhone，所以 iOS 27+ 用 ScreenCaptureKit，iOS 17–26 用 ReplayKit 录屏扩展。最低 iOS 17，因为快捷按钮依赖可交互的实时活动。

## Consequences

- 编码、截取、网络代码两条路线共用，而且要能在录屏扩展约 50MB 的内存上限里运行。
- 旧路线里 App 和扩展通信依赖 App Groups，免费开发者账号能不能用要实测。
- 两条路线拿到的画面方向信息都要真机验证。
