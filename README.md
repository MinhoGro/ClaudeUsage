# Claude 用量监控 · ClaudeUsage

一个 macOS 菜单栏小工具，实时显示 **Claude 订阅额度**——5 小时 / 7 天剩余、各模型用量、套餐与重置时间。常驻菜单栏，可选加入系统「编辑小组件」画廊。

![预览](preview.png)

*（上：浅色模式　下：深色模式——菜单栏点开后的下拉面板）*

## 功能

- **菜单栏常驻**：图标是电量式仪表盘环（按 5 小时剩余、20% 一档填充）+ 剩余百分比
- **点开下拉面板**：套餐徽章、5 小时 / 7 天重置倒计时、各项剩余额度横向 bar（5 小时 / 7 天 / 各模型如 Sonnet）、更新时间。透明背景融入菜单，深浅模式自适应
- **原生「编辑小组件」小组件**：内嵌 WidgetKit 扩展，桌面右键 →「编辑小组件」→ 搜「Claude」添加（小 / 中两种尺寸），iOS 电量圆环风格，白/深卡片随系统反转。带手动刷新按钮（↻）
- **桌面悬浮版**：钉在桌面层（墙纸之上、窗口之下）的圆环卡片（[预览](preview-widget.png)），**默认隐藏**，可从菜单栏「显示桌面组件」开启
- **每 60 秒自动刷新**，不依赖 Claude Code 是否在运行；颜色按剩余量绿/黄/橙/红

## 环境要求

- macOS 14+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：`brew install xcodegen`
- Xcode（提供 swiftc / WidgetKit 与签名）
- 一个 Apple ID（**免费**即可）——仅「编辑小组件」画廊需要带 Team ID 的签名；纯菜单栏/悬浮版不签名也能跑

## 构建与安装

```bash
./build.sh                                   # → build/ClaudeUsage.app
cp -R build/ClaudeUsage.app /Applications/   # 装进应用程序
open /Applications/ClaudeUsage.app           # 启动（菜单栏出现仪表盘图标）
./install-autostart.sh                       # （可选）登录时自动启动
```

`build.sh` 用 XcodeGen 生成工程、xcodebuild 编译，并自动从钥匙串里的 **Apple Development** 证书检测 Team ID。也可显式指定：`DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh`。检测不到证书时退化为 ad-hoc 构建（菜单栏/悬浮版可用，画廊小组件不可用）。

## 让「编辑小组件」里出现这个小组件（签名）

macOS 画廊后台 `chronod` 对第三方扩展有签名信任闸门：**只接受带真实 Apple 签发 Team ID 的签名**，ad-hoc / 自签名会被当场丢弃（不进画廊）。**免费 Apple Development 证书即可满足**，无需付费、无需上架。

1. Xcode → Settings → Accounts，登录 Apple ID（免费个人团队）→ Manage Certificates → `+` → **Apple Development**
2. 若构建时 `codesign` 报 `unable to build chain to self-signed root`，补装 Apple WWDR G3 中间证书（Xcode 偶尔漏装）：
   ```bash
   curl -fsSL -o /tmp/wwdr.cer https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
   security import /tmp/wwdr.cer -k ~/Library/Keychains/login.keychain-db
   ```
3. `./build.sh`（自动检测 Team ID）→ 装进「应用程序」并启动一次 → 桌面右键「编辑小组件」添加

> **局限**：开发签名只在本机/注册设备受信任，**无法分发给别人**；开发证书有效期约 1 年，到期重跑 `./build.sh` 重签即可。要分发给他人需付费 Apple Developer Program（$99/年）+ Developer ID 签名 + 公证（非上架 App Store）。

## 数据来源与隐私

主数据源是 **Anthropic 官方用量接口** `api.anthropic.com/api/oauth/usage`，用的是 **Claude Code 自己的登录令牌**（从钥匙串 `Claude Code-credentials` 或 `~/.claude/.credentials.json` 读取，**只读**，绝不修改/续期/上传）。

- 前提：终端里 `claude` 已用订阅账号登录。首次读钥匙串 macOS 会弹授权窗，点「始终允许」。
- 还会从 OAuth profile 自动识别套餐（Pro/Max），失败可在菜单里手选。
- **可选回退**：Claude Code 的 `statusLine` 钩子（`statusline.py`）把用量写进 `~/.claude/usage-cache.json`，无令牌时作为后备数据。手动启用：在 `~/.claude/settings.json` 加
  ```json
  "statusLine": { "type": "command", "command": "/绝对路径/statusline.py", "padding": 0 }
  ```

无任何密钥硬编码，全部本地运行；扩展沙箱化、只读自己的容器（由悬浮版把数据喂进去）。

## 刷新节奏

| 看哪里 | 节奏 |
|---|---|
| 菜单栏百分比 | ~15 秒 |
| 底层数据（API 轮询） | ≤60 秒 |
| 原生小组件画面重绘 | 由 WidgetKit 配额调度，约 5–15 分钟（倒计时文本每分钟实时跳） |
| 小组件刷新按钮 ↻ | 立即（触发悬浮版即时拉取 + 重载） |

## 项目结构

```
ClaudeUsage.m              菜单栏 app + 悬浮版（绘制、状态项、菜单面板、60s API 轮询、ping 检测）
WidgetReload.swift         @objc 桥：让 ObjC 调 WidgetCenter 重载小组件
widget/
  ClaudeUsageWidget.swift  WidgetKit 扩展（SwiftUI，含刷新按钮 AppIntent）
  widget.entitlements      仅 app-sandbox（读自身容器，故无需描述文件）
statusline.py              Claude Code statusLine 钩子（可选后备数据源）
project.yml                XcodeGen 工程定义（两个 target，签名由 build.sh 注入）
build.sh                   构建（XcodeGen + xcodebuild，自动检测签名）
make-icon.sh               生成 AppIcon.icns
install-autostart.sh       安装登录自启 LaunchAgent
AppIcon.icns               app 图标
```

## 技术要点

- 菜单栏 app 是 **Objective-C**（Cocoa + Security + WidgetKit）；WidgetKit 扩展是 **SwiftUI**；混合 target 由 XcodeGen 组装。
- 扩展只声明 `app-sandbox`、只读自己的容器；非沙箱的菜单栏 app 每 60s 把用量 JSON 镜像进扩展容器——因此无需任何受限授权或描述文件，一张 Team-ID 证书即可过画廊闸门。
- 小组件刷新按钮用 AppIntent：写一个 ping 文件 → 菜单栏 app 检测到 → 即时拉取 API → `WidgetCenter` 重载。
- 菜单栏状态项常驻；悬浮版窗口在 `NSNormalWindowLevel-1`（桌面层，可点击；不能用 `kCGDesktopIconWindowLevel`——那层鼠标事件会被 Finder 截走）。
- 离屏预览（不动屏幕）：`build/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --render-menu out.png` 或 `--render out.png`。

## License

MIT，见 [LICENSE](LICENSE)。与 Anthropic 无官方关联。
