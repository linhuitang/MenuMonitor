# MenuMonitor

macOS 菜单栏系统监控小工具，界面参考常见清理类应用的弹出面板。

## 功能

- 菜单栏实时显示 CPU / 内存占用
- 弹出面板：待清理垃圾估算、内存 / CPU / 温度、应用内存榜、磁盘 / 网络 / 硬件监控
- 「快速清理」仅清理 `~/Library/Caches`（有确认弹窗）
- 「释放」打开「活动监视器」
- 「硬件详情」打开「系统信息」

## 环境

- macOS 14+
- Apple Silicon / Intel
- 只需 Command Line Tools（`xcode-select --install`），不必装完整 Xcode

## 编译并安装

```bash
cd /Users/mac/Public/MenuMonitor
./build.sh
```

脚本会：`swift build -c release` → 组装 `MenuMonitor.app` → ad-hoc 签名 → 复制到 `/Applications` → 启动。

## 手动步骤

```bash
swift build -c release
# 然后运行 ./build.sh，或自行按 build.sh 里的步骤打包
```

## 退出

点击弹出面板右下角「退出」，或：

```bash
pkill -x MenuMonitor
```

## 说明

- CPU 温度通过 IOKit HID 传感器私有接口尽力读取；读不到时显示 `--`
- 垃圾体积为 `~/Library/Caches` + `~/.Trash` 的估算值，大目录会截断遍历以保证流畅
