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
- Flutter SDK **3.47.6**（FVM 管理，路径 `~/fvm/versions/3.47.6`，以 `.fvmrc` 为准）
- Xcode 27 + CocoaPods
- 走代理：`export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890`
- git 全局代理：`git config --global http.proxy http://127.0.0.1:7890`

### 打补丁（flutter clean 后必须重做）

PiliPlus 编译前必须给 Flutter SDK 和 material_ui 打补丁（暴露私有 API）：

```bash
cd ~/fvm/versions/3.47.6
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
fvm use 3.47.6
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
adb install -r build/app/outputs/flutter-apk/app-release.apk
adb shell appops set com.example.piliplus android:write_settings allow
adb shell dumpsys package com.example.piliplus.debug | grep versionCode   # 验版本真的换了
```

## 真机与双包（铁律）

- 设备：Redmi Turbo 3（peridot / Android 16 / 1220×2712 / density 480）。
- **双包并存**，别搞混：
  - `com.example.piliplus` = 正式版（桌面图标，载着用户账号和全部设置）
  - `com.example.piliplus.debug` = 测试版（抽屉图标，app 名 "PiliPlus Debug"）
- **正式包绝不可卸载**（用户明确要求，卸载会丢账号与已调设置）；升级一律 `adb install -r`。
- **versionCode 铁律**：每次真机测试前递增 `pubspec.yaml` 的 `version:`（如 `2.1.6+11` → `+12`）。
  HyperOS 上相同 versionCode 的 `install -r` 会报 Success 但旧进程/旧代码继续跑，
  装完必须用 `dumpsys package ... | grep versionCode` 核对。
- **不要擅自 `adb exec-out screencap`**：用户常在语音输入+随手测试，突然截屏会抓到无关画面。
  先把已完成的工作汇报完 → 说明需要他进入哪个页面 → 得到同意再截图。

## ADB 连接

- 设备：Redmi Turbo 3
- mDNS 地址：`adb-da0fda92-Eo7NE1._adb-tls-connect._tcp`
- **VPN 开着时 ADB 无法连接**（无线调试绑定到 TUN 接口），需关 VPN 或用 USB 线
- mDNS 解析失败时，用无线调试页面显示的 IP 直连：`adb connect 192.168.x.x:port`

## 构建脚本（rvs 26.9.23）

- `test.rvs` — Mac 端：clean + build macos --release + 启动。`rvs test.rvs`
- `build.rvs` — 全量：敏感检查 → Mac → Android → 装手机 → 重启 Mac app。`rvs build.rvs`
- rvs 不实现 POSIX 内建，脚本里必须遵守：
  - 代理用 `env "https_proxy=..." "http_proxy=..." <命令>` 注入，**不要 `export`**
  - **不要 `$VAR` 赋值、`$(...)` 命令替换**（直接 Parse error）
  - 条件只认 `if (<命令>)`，按退出码判真假（例：`if (adb get-state) { ... }`）
  - 遇失败命令自动中止，**不需要 `$LASTEXITCODE`**
  - `mv` 是 rvs 内置别名，不认 `-f`，要带参数就用 `/bin/mv`
- 改完脚本先用 `rvs --dry-run build.rvs` 验语法，别直接全量跑。

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

## 提交规范

- 提交信息用 Conventional Commits（`feat:` / `fix:` / `docs:` / `chore:` 等），主题中文描述即可。
- 末尾 trailer（空行隔开）用 `Co-Authored-By`，名字填写实际执行本次提交的模型/Agent，不知道则不写。
- 本仓库公开，提交前确认无私钥/token/个人邮箱/VPS地址泄漏（`scripts/bash/check-sensitive.sh` 已配置 pre-push hook 自动检查）。

## 推送政策

- **本仓库即改即推，不需要用户批准**（用户已明确授权）：改完 → 构建验证 → commit → `git push github-fork main`。
- 例外：**其他仓库/项目的外发（PR、issue、评论、邮件）仍须用户明确批准**，不要类推。
- 临时文件、交接文档、笔记一律放 `/private/tmp/`，不要进仓库（避免被误 `git add`）。

