# 屏幕录制权限

应用启动只查询系统当前的录屏授权，不再按构建哈希调用 `tccutil reset`，也不改写系统权限数据库。第一次启用实时桌面效果时，仍需用户在 macOS 的「录屏与系统录音」中允许 MacBook Duo。

## 本机固定签名

临时 ad-hoc 签名通常以代码哈希识别构建，重新编译可能导致旧授权不再匹配。固定证书与 Bundle ID 可以让 macOS 按同一个应用身份识别后续更新。

```sh
python3 Tools/setup-local-signing.py
./build.sh
```

设置脚本创建名为 `MacBook Duo Local Development` 的本地代码签名证书，并按系统提示完成用户验证：

- 私钥导入登录钥匙串，设为不可导出，仅授权系统 `codesign` 工具使用。
- 证书用途限于代码签名，信任配置限于当前用户；不用于 TLS 或签发其他证书。
- 公共证书和身份指纹保存在 `~/Library/Application Support/MacBook Duo/Signing/`，私钥和临时导入材料不进入仓库。
- 主应用和内置扩展由 `Tools/sign-app.sh` 使用同一固定身份签名。`DUO_SIGNING_IDENTITY` 可以覆盖本机配置；设为 `-` 可显式构建 ad-hoc 版本。

从旧 ad-hoc 版本首次迁移到固定证书时，通常仍需重新授权一次。后续应保持证书、Bundle ID 和安装路径一致；系统撤销授权或要求再次确认时，仍需用户处理。

本地自签证书用于本机开发，不等同于 Developer ID 签名或公证。正式分发需配置相应开发者签名及公证流程。
