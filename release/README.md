# 预编译包

`ClaudeUsage.dmg` — 最新构建的 ClaudeUsage.app（菜单栏 + 原生小组件）。

## 重要：签名限制

此包用**免费 Apple Development 证书**签名，**只在构建它的那台 Mac 上受信任**：

- 在别人机器上双击会被 Gatekeeper 拦下（「无法验证开发者」），原生「编辑小组件」也不会出现（macOS 会丢弃不受信任扩展的描述符）。
- 开发证书约 1 年到期。

**所以这个 DMG 主要是构建者本机用 / 留档。** 其他人请用自己的 Apple ID 从源码构建（见仓库根目录 README 的「构建与安装」），或等作者提供 Developer ID 公证版。

## 安装（在构建它的那台 Mac 上）

1. 打开 `ClaudeUsage.dmg`，把 `ClaudeUsage.app` 拖进「应用程序」
2. 启动后菜单栏出现仪表盘图标
3. 桌面右键「编辑小组件」→ 搜「Claude」可添加原生小组件
