# 电脑端用 Electron + WebCodecs

代码主要由 AI 写、用户测试，要让自己写的底层代码最少。Electron 现成提供硬件解码（WebCodecs）、无边框全屏、HTML 浮层、托盘、开机自启、防休眠和 TLS，所以电脑端用 Electron + TypeScript，不用 C#/.NET 或 C++ 原生。

## Consequences

- 安装包约 80–100MB，托盘常驻约占 100MB 内存。
- SPS 没声明 `max_num_reorder_frames=0` 时，WebCodecs 硬解会攒帧、增加延迟：喂解码器前要检查并改写 SPS，不行再退回软解。
- 解码出的 VideoFrame 必须立即 close，否则硬解输出池会卡住。
