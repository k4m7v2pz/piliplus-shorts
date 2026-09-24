# PiliPlus Shorts — Agent 构建指南

本仓库是 [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的 fork，
新增竖屏短视频上下滑 feed。应用名 **PiliPlus Shorts**。

## 远程仓库

| remote | 地址 | 用途 |
|--------|------|------|
| `origin` | `https://github.com/bggRGjQaUbCoE/PiliPlus.git` | 上游，只读 |
| `github-fork` | `git@github.com:k4m7v2pz/piliplus-shorts.git` | 主仓库（公开） |
| ~~`atomgit`~~ | ~~`git@atomgit.com:k4m7v2pz/piliplus.git`~~ | 已归档，不再推送 |

## 快速编译

### 前置条件
- Flutter SDK **3.47.5**（FVM 管理，路径 `~/fvm/versions/3.47.5`）
- Xcode 27 + CocoaPods
- 走代理：`export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890`
- git 全局代理：`git config --global http.proxy http://127.0.0.1:7890`

### 打补丁（flutter clean 后必须重做）

PiliPlus 编译前必须给 Flutter SDK 和 material_ui 打补丁（暴露私有 API）：

```bash
cd ~/fvm/versions/3.47.5
PILI=<仓库绝对路径>

# Flutter SDK patches
for patch in "$PILI"/lib/scripts/*.patch; do
  git apply "$patch" 2>/dev/null
done

# material_ui patches（注意版本号，pub get 后会变）
MATVER=$(ls -d ~/.pub-cache/hosted/pub.dev/material_ui-* | tail -1)
cd "$MATVER"
for patch in "$PILI"/lib/scripts/material/*.patch; do
  git apply "$patch"
done
# 删除 popGestureEnabled 行
sed -i '' '/popGestureEnabled: true,/d' lib/src/scaffold.dart
```

**注意**：`git apply` 对已打过补丁的文件会报错，忽略即可（用 `2>/dev/null`）。

### 编译命令

```bash
cd <仓库路径>
export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890
fvm use 3.47.5
fvm flutter pub get

# Mac
fvm flutter build macos --release
# 产物：build/macos/Build/Products/Release/PiliPlus.app

# Android
fvm flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

### Android 安装后必做
```bash
adb -s <设备地址> install -r build/app/outputs/flutter-apk/app-release.apk
adb -s <设备地址> shell appops set com.example.piliplus android:write_settings allow
```

## ADB 连接

- 设备：Redmi Turbo 3
- mDNS 地址：`adb-da0fda92-Eo7NE1._adb-tls-connect._tcp`
- **VPN 开着时 ADB 无法连接**（无线调试绑定到 TUN 接口），需关 VPN 或用 USB 线
- mDNS 解析失败时，用无线调试页面显示的 IP 直连：`adb connect 192.168.x.x:port`

## 合并上游

```bash
git fetch origin
git merge origin/main
# 冲突通常在：MainActivity.kt（保留竖屏锁定代码）、pubspec.yaml（media-kit ref）
```

合并后需要重新打补丁（flutter clean 会清除 SDK 补丁）。

## 短视频功能文件

- `lib/pages/short_video/controller.dart` — GetX Controller，单 mpv 播放器
- `lib/pages/short_video/view.dart` — PageView 上下滑、封面 overlay、进度条
- `assets/short_video_filter.json` — 屏蔽规则（热更新，推到 `/sdcard/Android/data/com.example.piliplus/files/`）
- `lib/common/constants.dart` — `sourceCodeUrl` 指向 GitHub fork

## 敏感信息守卫

`scripts/bash/check-sensitive.sh` 在推送到 `github-fork` 前自动检查：
公网 IP、SSH 密钥、私钥内容、私人邮箱、机器标识（vultr/thinkpad）。
已在 `.git/hooks/pre-push` 配置，只对公开 fork 触发。

## 已知问题

- macOS 退出时 SIGABRT（FFI 回调，不影响使用）
- 单 mpv 播放器切视频有短暂加载（曾试 3/4 实例预加载，均导致视频错位，已回退）
- 异步屏蔽检查（音乐/标签）必须加 generation 守卫，否则用户滑走后误跳转
- `videoControllers` 必须用 `RxMap`，否则 Obx 不 rebuild
- Mac 端 incremental build 会丢失 media_kit 插件链接，必须 `flutter clean` 后重编
- macOS Sandbox 下 `File()` 路径会被重定向到 `~/Library/Containers/com.example.piliplus/Data/`
