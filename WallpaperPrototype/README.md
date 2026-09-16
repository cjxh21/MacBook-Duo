# MacBook Duo 锁屏墙纸扩展

锁屏墙纸扩展现在由根目录 `build.sh` 嵌入工作区生成的 `MacBook Duo.app`（安装时可复制到 `/Applications`），主 App 发布正式版同一份开合数据，设置页可以导入自定义图片。`WallpaperPrototype/build.sh` 仍保留为独立调试构建，不应与正式版同时运行。扩展不录屏、不处理密码框。参考 Phosphene 的私有 WallpaperExtensionKit 接入方式；许可证和提交号保存在 Vendor。

## 已验证

- 本机 macOS 26.6.2 编译、ad-hoc 签名验证。
- pluginkit 能登记 `studio.prototype.DuoWallpaper.extension`。
- 2026-09-14 20:58，WallpaperAgent 实际启动扩展并完成 provideSettingsViewModels；系统墙纸页已出现两个 Duo 选项。
- 启动修复：Contents/Extensions 打包，并使用 `_NSExtensionMain` 链接入口，保持与 Xcode ExtensionKit 目标一致。
- 2026-09-14 21:36，选择 `Duo · 动态验证` 后，WallpaperAgent 完成真实的 Acquire Wallpaper、首帧入队、远程 CA 合成和运行时更新；随后选择 `Duo · 随开合变化` 也完成同样流程。
- 壁纸角度路径沿用正式版 `HingeMotion`、预测值、清晰区边界和 `GlassMetalView` 的 25 ms 角度跟随；扩展只负责把结果送入 WallpaperExtensionKit。
- 终点角度、运动预测、磨砂和边缘柔和度从正式版的 `studio.prototype.HingeGlass.Global` 设置读取，壁纸不再使用独立的固定外观参数。
- 视频队列只给切换后的首帧使用 `DisplayImmediately`，后续帧使用 30 fps 时间轴，并在 GPU 完成后再取显示时间，避免快速合拢时每帧强制抢占显示节奏。
- 本机真实 WallpaperSettingsViewModelsXPC 解码成功、CAContext 和 WallpaperRemoteContextXPC 构造成功。
- IOSurface + Metal 离屏渲染，复用正式版 GaussianPyramid 和 glassMain；三次角度绘制只构建一次模糊层。
- 共享角度文件读取、过期和未来时间戳拒绝。

## 尚未验证

本次构建已经完成扩展包结构、签名、离屏渲染、系统设置选项切换和 WallpaperAgent 的真实 acquire；用户侧仍需在锁屏界面实际确认两种时序：展开状态从黑屏唤醒的一次翻页，以及物理开合时的角度跟随。当前墙纸层上限为 30fps，不把它当作端到端显示帧率验收。

## 内容和生命周期

两个选项：`Duo · 动态验证` 用自动角度循环检验显示；`Duo · 随开合变化` 仅锁屏时按角度变形，普通桌面显示清晰测试图。导入自定义图片后，第二项显示为 `Duo · 随开合变化（自定义）`。无新角度时 0.5 秒内回到清晰。锁屏墙纸只改变背景，时钟、密码框和输入控件仍由 macOS 绘制。

角度桥使用 `~/Library/Application Support/MacBook Duo/Wallpaper/duo-state-v2.bin`，80 字节 mmap + flock；主 App 只打开扩展已创建的文件，不主动伪造沙箱容器。墙纸读取正式版同一份校准、预测、磨砂和边缘柔和度设置。进入息屏时提交一次全黑的折叠起始帧，随后停止绘制并保留轻量计时器等待唤醒。

## 构建和离屏测试

```sh
zsh WallpaperPrototype/build.sh
zsh WallpaperPrototype/test.sh
```

正式产物：根目录的 `MacBook Duo.app`，其中包含 `Contents/Extensions/DuoWallpaper.appex`。测试图：`build/validation/angle-115.png`、`angle-100.png`、`angle-65.png`。

## 上屏验证（等用户方便）

1. 保存当前壁纸选择，确认能恢复。确认 `/Applications/MacBook Duo.app` 已在后台运行。
2. 系统设置 → 墙纸，寻找“MacBook Duo · 锁屏壁纸”。若未出现，先检查扩展登记和签名，不重启系统壁纸进程。
3. 先选“动态验证”，观察标签和背景是否动，再手动锁屏。
4. 成功后选“随开合变化”，再次锁屏测试角度。
5. 恢复原壁纸即可；无需删除正式版或重新授权录屏。

日志通过 Console 或 `log show --last 5m --predicate 'eventMessage CONTAINS "DuoWallpaper"'` 检查。原型的纯色背景不涉及用户屏幕内容。

取消扩展登记（先恢复原壁纸）：

```sh
pluginkit -r "$PWD/WallpaperPrototype/build/Duo Wallpaper Lab.app/Contents/Extensions/DuoWallpaper.appex"
```

私有框架版本变化可能造成加载或快照失败。本实现不安装 LoginWindow helper、不修改认证组件、不重启 WallpaperAgent，不自动选择壁纸。

## 本轮上屏验证状态（2026-09-15）

0.9.5 已重新编译、签名并安装到 `/Applications/MacBook Duo.app`，扩展已重新登记。系统设置显示 `Duo · 动态验证` 和 `Duo · 随开合变化（自定义）` 两个选项，当前选中后者；WallpaperAgent 日志出现真实 `Acquire Wallpaper`、首帧合成和运行时更新，扩展进程持续输出 1470×956 帧，CoreMedia 统计没有黑帧替换。锁屏角度跟随和唤醒翻页仍需在实际锁屏/掀盖动作下验收。

## 展开状态唤醒动画

检测到屏幕休眠后再次唤醒，且锁屏时新鲜角度数据表明盖子已到校准的清晰区，会按主应用设置中的统一耗时播放一次自动翻开动画（默认 0.9 秒，使用从底边展开的独立透视渲染），随后恢复清晰壁纸。重复唤醒通知不会重播；实际掀盖继续跟随传感器；解锁、再次休眠或角度离开清晰区会取消动画。等待锁屏和新鲜数据最多 2 秒，超时放弃。息屏时预先提交黑色起始帧，唤醒时清空旧队列；等待新鲜数据期间保持黑场，避免先显示正常壁纸再开始动画。

此逻辑已加入离线回归测试；真实锁屏下的通知时序及可见动画仍需本机亮屏验收。

## 2026-09-15 黑屏排查

此前的黑屏现象来自旧扩展缓存和旧登记项，导致设置页点击没有进入新的 WallpaperAgent provider。现在通过替换完整应用、重新登记扩展并移出旧 view-model cache，系统设置已经能显示并选中自定义 Duo 选项；0.9.5 也为布尔回复补充了 XPC reply 参数白名单。后续仍以实际锁屏唤醒画面为最终验收，不把设置页预览或离屏测试当作物理锁屏证明。

## 0.9.6：统一唤醒耗时与恢复状态

桌面与锁屏共用耗时和缓动曲线，耗时通过 v2 角度桥传递。v2 使用新文件名，不改写旧扩展仍可能映射的 v1 文件。定时核对实际显示器电源状态，避免漏掉唤醒通知后保持暂停；主应用也核对会话锁定状态，恢复壁纸所需的传感器采样。

## 0.9.7：独立的开盖渲染

唤醒通过共享的 `wakeMain` 着色器把整张图像作为单个平面，绕屏幕下沿单向展开，使用两端平滑的统一时间曲线。唤醒帧复用高斯金字塔，从模糊逐渐变清晰，完全展开后与正常图像像素一致。真实铰链运动继续使用 `glassMain`。墙纸被隐藏时的 activity suspension 不再被当成显示器息屏。

共享壁纸和角度文件位于专用 Wallpaper 目录。扩展通过仅限此目录的文件访问 entitlement 读写；主应用不再访问扩展私有容器。扩展首次启动迁移旧壁纸，不覆盖新导入，不迁移过期角度。此本机开发方案使用 Apple 文档中的 temporary-exception.files.home-relative-path.read-write，正式分发应评估 App Group。
