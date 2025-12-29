# Fix Tim

[English](./README.md) | [中文文档](./README_CN.md)

修复 macOS 上的各种问题。

![screenshot](./Resources/SCR-20240206.gif)

## 这是什么？

在很多情况下，我们需要重启 Mac 来修复系统故障。这个易用的工具能够在不需要完整重启系统的情况下解决大多数运行时问题，并且可以将您的应用程序恢复到问题发生前的状态。

该工具可以解决如下问题：

- 桌面截图功能失效
- 输入法卡顿
- 核心音频流中断
- AirDrop 故障或效率低下
- Wi-Fi 无法扫描或连接
- 任何无响应或转圈的应用
- iCloud 同步问题
- Xcode 找不到设备
- Xcode 模拟器无法启动
- debugserver 无响应

还有更多...

**请注意，此应用无法修复硬件问题或内核级错误。**

---

## ✨ 增强功能

此增强版本添加了对启动项的全面支持：

### 新功能
- ✅ **完整的 LaunchAgents 支持** - 软重启后自动重新加载用户级 LaunchAgents
- ✅ **登录项支持** - 重启系统设置中配置的所有登录项
- ✅ **扩展的应用搜索** - 支持任意位置的应用程序，不仅限于 `/Applications`
- ✅ **后台启动** - 登录项在后台静默启动（使用 `-g` 参数）
- ✅ **命令行选项** - 新增参数：`--no-launch-agents` 和 `--no-login-items`

### Bug 修复
- 🐛 修复了 `listApplications()` 中的数组越界错误（`0 ... entryCount` → `0 ..< entryCount`）
- 🐛 移除了应用路径限制（之前仅限于 `/Applications/` 和 `/System/Applications/`）
- 🐛 为 LaunchAgents 和登录项添加了完善的错误处理

### 修改的文件
- `FixTim/ListApps.swift` - 为 GUI 版本添加了 LaunchAgents 和登录项支持
- `FixTim/App.swift` - 添加了新的设置开关和重启逻辑
- `Resources/CommandLineTool.swift` - 将所有增强功能同步到命令行版本

---

## 系统要求

- **macOS 10.10+** - 基础功能
- **所有 macOS 版本** - 完整的 LaunchAgents 和登录项支持（通过 AppleScript）

> **注意**：登录项支持使用 AppleScript 查询系统事件，适用于所有 macOS 版本，无需 macOS 13+ API。

---

## 安装方式

### 方法 1：GUI 应用程序（推荐）

#### 从源代码构建：
```bash
# 切换到 Xcode 命令行工具
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer

# 无需代码签名构建（不需要开发者账号）
cd "/path/to/FixTim-main"
xcodebuild -project FixTim.xcodeproj -scheme FixTim -configuration Release \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

# 应用程序将位于：
# ~/Library/Developer/Xcode/DerivedData/FixTim-*/Build/Products/Release/FixTim.app

# 复制到应用程序文件夹
cp -R ~/Library/Developer/Xcode/DerivedData/FixTim-*/Build/Products/Release/FixTim.app /Applications/
```

#### 首次启动（安全设置）：
如果 macOS 阻止应用运行，执行：
```bash
xattr -cr /Applications/FixTim.app
```

或前往 **系统设置 → 隐私与安全性** 并点击"仍要打开"。

---

### 方法 2：命令行工具

适用于 macOS 13.0 以下版本或偏好使用终端的用户：

```bash
# 编译
swiftc -o fixtim -framework AppKit -framework ServiceManagement ./Resources/CommandLineTool.swift

# 直接运行
./fixtim

# 或安装到系统路径
sudo cp fixtim /usr/local/bin/
sudo chmod +x /usr/local/bin/fixtim
```

#### 命令行选项：
```bash
fixtim                      # 完整重启，包含所有功能
fixtim --no-launch-agents   # 跳过 LaunchAgents 重新加载
fixtim --no-login-items     # 跳过登录项重启
fixtim --help               # 显示帮助信息
```

---

## macOS 13.0 以下版本

命令行工具在旧版本 macOS 上完美运行：

```bash
swiftc -o fixtim -framework AppKit -framework ServiceManagement ./Resources/CommandLineTool.swift
./fixtim
```

所有功能（包括 LaunchAgents 和登录项支持）完全兼容旧版本 macOS。

---

## 工作原理

我们使用 launchd 启动重启进程，然后重新打开应用程序。此重启不涉及重新加载内核，仅重新加载用户空间。

这个过程类似于 Android 的软重启，速度快且不消耗大量资源。

### 恢复的内容：
1. **运行中的应用程序** - 重启前正在运行的所有应用
2. **LaunchAgents** - 用户级后台服务（可选）
3. **登录项** - 配置为登录时启动的应用程序（可选）
4. **Dock 布局** - 您的 Dock 配置

---

## 管理员权限

大多数问题不需要管理员权限，但某些问题需要。如果需要，请在终端中使用参数 `--now` 执行：

```bash
sudo /Applications/FixTim.app/Contents/MacOS/FixTim --now
```

---

## 原作者
#### GitHub
https://github.com/Lakr233/FixTim
#### Twitter
https://x.com/Lakr233