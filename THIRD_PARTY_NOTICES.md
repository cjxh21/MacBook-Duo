# 第三方代码、参考与归属

## 视觉概念与演示来源

MacBook Duo 的悬浮玻璃和屏幕随开合变化的视觉概念，参考了 B 站 UP 主 **Apple 江灵夏草** 的视频：

- [我在MacBook上实现了iPhone Duo的悬浮玻璃效果](https://www.bilibili.com/video/BV18sYV6uERz/)

该视频是视觉创意和效果演示的参考来源，不构成对视频内容或代码的开源授权。本仓库没有把视频描述为代码版权来源。

## Phosphene

锁屏壁纸扩展中的部分适配代码参考并复用了 [kageroumado/phosphene](https://github.com/kageroumado/phosphene) 的实现，当前固定到以下提交：

```text
8b5bd57c1450eda74cf2ec6ceaae2e586cfdfcd6
```

保留的范围包括 Codable、运行时对象封装和 XPC 协议声明；主 App、铰链数据桥、角度状态和 Metal 渲染器是本地实现。Phosphene 的 MIT 许可全文见 [`WallpaperPrototype/Vendor/LICENSE-Phosphene`](WallpaperPrototype/Vendor/LICENSE-Phosphene)，来源记录见 [`WallpaperPrototype/Vendor/PROVENANCE.md`](WallpaperPrototype/Vendor/PROVENANCE.md)。

## 其他参考

- 投影模型参考：[Atomicx7/Duo-animation](https://github.com/Atomicx7/Duo-animation)。
- 铰链 HID 读取参考：[samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)。

这些项目的代码范围和许可证应以各自仓库当前文件为准；本仓库不会把参考链接误写成完整代码来源。

## 本项目许可证

本仓库自有代码采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。允许许可范围内的非商业使用、修改和分发；商业用途需另行授权。

Required Notice: Copyright (c) 2026 cjxh21

本声明不替换第三方代码的原有许可证。`WallpaperPrototype/Vendor/` 中来自 Phosphene 的代码仍按其 MIT 许可提供，保留原有版权、许可全文和固定提交记录。
