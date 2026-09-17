# 两端都用自研 App 和自定义协议

智能截取、智能旋转、配对设备管理都要在手机端实现，只有自研的手机 App 能做到。所以手机端和电脑端都是自研 App，用自己的协议通信（见 `docs/protocol.md`），不做 AirPlay、Miracast、DLNA 接收。

## Considered Options

- AirPlay 接收：需要逆向 FairPlay，违反"不用逆向协议"的约束。
- Miracast：很多手机不支持，也做不了截取和旋转。
- DLNA 接收：只能投视频 App 里的片源，不是屏幕投屏；国内 App 兼容问题多。

## Consequences

- 有版权保护的视频（会员片等）录屏是黑屏，记为已知限制。
- 协议要在 Kotlin、Swift、TypeScript 各实现一遍，必须保持极简。
