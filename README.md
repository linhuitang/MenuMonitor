# MenuMonitor

macOS 菜单栏系统监控小工具（原生 SwiftUI / AppKit）。

> A lightweight macOS menu-bar system monitor built with SwiftUI and AppKit.

![Panel screenshot](docs/screenshot.png)

## 功能

- **菜单栏**：实时显示内存占用百分比
- **弹出面板**
  - 待清理缓存估算与「快速清理」（清理 `~/Library/Caches`，无二次确认，带进度）
  - 内存 / CPU / CPU 温度
  - 应用内存占用 Top 10（可结束进程、查看详情）
  - 磁盘空间、网络与磁盘 I/O 速率
  - 「管理进程」打开「活动监视器」；「硬件详情」打开「系统信息」
- **退出**：右键菜单栏图标 →「退出 MenuMonitor」（左键打开/关闭面板）

## 环境要求

- **macOS 14+**（见 `Package.swift`）
- Apple Silicon 或 Intel（CPU 温度优先通过 IOKit HID 传感器读取，读不到时显示 `--`）
- 仅需 **Command Line Tools**（`xcode-select --install`），不必安装完整 Xcode

## 编译与安装

```bash
git clone https://github.com/linhuitang/MenuMonitor.git
cd MenuMonitor
./build.sh
```

`build.sh` 会：`swift build -c release` → 组装 `MenuMonitor.app` → ad-hoc 签名 → 安装到 `/Applications` → 启动。

仅编译：

```bash
swift build -c release
```

## 退出

- 右键菜单栏图标 → **退出 MenuMonitor**
- 或终端：`pkill -x MenuMonitor`

## 说明

- 「快速清理」只删除用户 `~/Library/Caches` 下可安全清理的内容，不会动废纸篓或其他目录
- 待清理体积低于 1 MiB 时显示「没有要清理的垃圾」，并禁用快速清理按钮
- 本项目以 ad-hoc 签名分发；若 Gatekeeper 拦截，可在「系统设置 → 隐私与安全性」中允许，或自行签名

## 许可证

MIT © 2026 linhuitang
