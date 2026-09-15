# MacBook Duo

macOS 菜单栏应用：读取 MacBook 铰链角度，用 Metal 为实时桌面生成透视和渐变磨砂效果，并提供锁屏壁纸扩展、截图测试及息屏唤醒动画。

## 环境要求

- macOS 26.0 或更高版本，支持 Metal 的 Mac。
- 实际开合跟随需要兼容的铰链传感器；HID 传感器通路和锁屏壁纸接入使用非公开接口，机型及系统版本兼容性需要实际验证。
- 构建需要 Apple Command Line Tools，无需完整 Xcode 或下载第三方依赖。

## 构建与运行

```sh
xcode-select --install  # 已安装命令行工具时跳过
./build.sh
open "MacBook Duo.app"
```

构建脚本生成当前 Mac 架构的应用，并内置 `Contents/Extensions/DuoWallpaper.appex`。Metal 着色器在运行时编译。应用属于未公证的开发版；构建优先使用本机配置的固定签名身份，未配置时使用 ad-hoc 签名。

本机开发可先运行一次 `python3 Tools/setup-local-signing.py`，按 macOS 提示完成钥匙串验证。后续构建自动复用此身份；私钥保存在登录钥匙串，签名配置位于用户的 Application Support 目录。也可通过 `DUO_SIGNING_IDENTITY` 指定现有代码签名身份。

若默认 SDK 出现 `this SDK is not supported by the compiler` 或缺少 `SwiftUIMacros` 插件，可为当次构建指定兼容的 SDK。以下示例使用已安装的 Command Line Tools 和 macOS 26.5 SDK：

```sh
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
./build.sh
```

请使用本机实际存在的 SDK 路径；使用完整 Xcode 时，将上述路径换成对应的开发工具和 SDK 目录。

应用启动只检查已有录屏授权，不再按构建自动重置。首次授权仍由用户在系统界面允许；固定签名有助于后续更新保留授权，详见 [PERMISSIONS.md](PERMISSIONS.md)。

## 实时桌面效果

1. 打开应用，在设置中授权屏幕录制并启用效果。
2. 将屏幕打开到舒适位置，通过菜单「设为展开位置」保存校准终点，默认 120°。
3. 缓慢合拢屏幕观察透视和磨砂变化；再次展开到清晰区时恢复正常桌面。
4. 菜单提供「预览 8 秒」、性能模式和设置入口。性能模式会根据电源状态调整捕获、渲染和传感器采样频率。

全局快捷键：⌘⇧G 启用／停止效果，⌘⇧K 校准，⌘⇧Esc 紧急停止。菜单可重新打开设置或退出应用。

### 未锁屏息屏后的唤醒动画

启用效果后，屏幕在未锁屏状态下闲置息屏、再次唤醒，会自动播放一次翻盖动画。新桌面画面完成首次 GPU 绘制后才开始计时；重复唤醒通知不会重新播放或重置画面。应用核对实际屏幕和会话状态，恢复遗漏唤醒通知时残留的暂停状态，也保留息屏期间临时锁定、唤醒后立即自动解锁的桌面动画。锁屏界面的效果由壁纸扩展呈现；预先手动锁屏或延迟解锁走锁屏壁纸动画。

设置窗口 →「效果」→「息屏唤醒动画」中的「动画耗时」支持 **0.3、0.6、0.9、1.5、2、3 秒**，默认 **0.9 秒**，选择会自动保存，并与菜单栏「息屏唤醒动画耗时」同步。桌面与锁屏壁纸共用此耗时设置。

唤醒使用独立的透视开盖渲染：画面从黑场绕屏幕下沿展开，起止平滑，结束帧与正常画面一致。真实铰链运动继续使用透视与磨砂效果。桌面会在息屏时准备黑色过渡层，并提前编译渲染器；新画面完成 GPU 绘制后再交给动画。唤醒动画无需等待铰链采样恢复，超过 2 秒仍未取得首帧则放弃这次动画，避免迟到后突然接管。

设置中的「预览翻盖动画」可按当前耗时立即播放一次，预览会启用实时桌面效果。

## 锁屏壁纸

在设置的壁纸页导入 PNG、JPEG、HEIC 或 TIFF 图片，再到系统设置 → 墙纸中选择「MacBook Duo · 锁屏壁纸」下的「Duo · 随开合变化（自定义）」。扩展依赖主应用提供铰链快照，使用时保持主应用运行。

锁屏壁纸沿用主应用的展开终点、预测、磨砂和边缘柔和度。展开状态下息屏后唤醒且取得新鲜角度数据时，按设置中的统一耗时播放一次翻页；实际开合继续跟随传感器。扩展只改变壁纸背景，时钟、密码框和输入控件由 macOS 管理。

扩展结构、调试入口和验证边界见 [WallpaperPrototype/README.md](WallpaperPrototype/README.md)。

## 截图测试

设置中导入完整桌面截图并开始测试。可关闭实时铰链并用滑杆模拟角度，或切换原图对比。测试页快捷键：⌘H 隐藏／恢复控制界面，Esc 显示控制界面，⌘K 保存展开终点，⌘B 原图对比，⌘Q 退出。

本实现以固定观察点模拟空间深度，没有头部跟踪；每张截图或捕获画面是一个内容平面，不会自动分离窗口。图像处理在本机进行，不保存屏幕录像。

## 测试

```sh
./test.sh                       # 角度、运行策略、权限、记录及桌面唤醒状态测试
./WallpaperPrototype/test.sh    # 壁纸桥、锁屏唤醒及离屏渲染测试
./Tools/test-renderer.sh        # Metal 渲染生命周期测试
./Tools/validate-ui.sh          # 设置页渲染与菜单结构检查
```

渲染和 UI 检查需要可用的 macOS 图形会话。测试输出不进入源码提交。自动测试不能代替真实息屏、锁屏及物理开合时的可见效果验收，也不能用于宣称端到端延迟或耗电表现。

开发工具及目录说明见 [源码说明.md](源码说明.md)。

## 下载与 Release

源码仓库保存源码、构建脚本、图标及第三方声明。应用、`dist/` 安装包和验证数据均不提交到 Git。

当前主应用元数据版本为 `0.8.2`，壁纸扩展版本为 `0.9.7`。发布前应统一核对版本与安装包内容，再创建对应标签，并在 Release 中附上包文件、变更说明、已知限制及 SHA-256 校验值。本地已有安装包不代表已包含最新源码改动。

## 来源、归属与实现范围

- 视觉概念和效果演示参考 B 站 UP 主 **Apple 江灵夏草** 的视频：[我在MacBook上实现了iPhone Duo的悬浮玻璃效果](https://www.bilibili.com/video/BV18sYV6uERz/)。
- 锁屏壁纸扩展的部分适配参考并复用了 [kageroumado/phosphene](https://github.com/kageroumado/phosphene)，固定提交和代码范围见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 与 [`WallpaperPrototype/Vendor/PROVENANCE.md`](WallpaperPrototype/Vendor/PROVENANCE.md)。
- 投影模型参考 [Atomicx7/Duo-animation](https://github.com/Atomicx7/Duo-animation)，铰链 HID 读取参考 [samhenrigold/LidAngleSensor](https://github.com/samhenrigold/LidAngleSensor)。

本仓库对主 App、铰链数据桥、角度状态和 Metal 渲染器做了本地实现；第三方许可全文保留在 `WallpaperPrototype/Vendor/`。完整归属说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 许可证

本项目自有代码采用 [PolyForm Noncommercial 1.0.0](LICENSE)，允许许可范围内的非商业使用、修改和分发。商业使用需另行取得授权。由于限制商业用途，本项目属于「源码可用」，不标称为 OSI 定义的开源软件。具体许可范围以 [许可证全文](LICENSE) 为准。

Required Notice: Copyright (c) 2026 cjxh21

第三方代码继续适用原有许可，不受本项目新增的非商用条件约束，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
