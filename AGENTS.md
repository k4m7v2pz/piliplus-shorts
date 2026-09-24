# PiliPlus 短视频版 — Agent 构建指南

本仓库是 PiliPlus 的私有 fork，添加了竖屏短视频（上下滑）功能。
基于上游 `bggRGjQaUbCoE/PiliPlus` main 分支。

## 快速编译 macOS

### 前置条件
- Flutter SDK 3.47.4（用 FVM 管理，路径 `~/fvm/versions/3.47.4`）
- Xcode 27.0（需 `sudo xcodebuild -license accept`）
- CocoaPods（`/opt/homebrew/bin/pod`）
- 走代理：`export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890`

### 关键步骤（CI patch）
PiliPlus 编译前必须给 Flutter SDK 打补丁（暴露私有 API），否则编译失败：

```bash
cd ~/fvm/versions/3.47.4
PILI=<仓库路径>
for patch in modal_barrier text_selection mouse_cursor image_anim layout_builder \
  navigation_drawer popup_menu fab null_safety_for_selectable_region \
  selectable_region editable_text text_field scroll_position scrollable \
  scrollable_gesture draggable_scrollable_sheet scaffold text text_painter \
  sliver refresh_indicator; do
  git apply "$PILI/lib/scripts/$patch.patch"
done
```

还要给 material_ui 包打补丁：
```bash
cd ~/.pub-cache/hosted/pub.dev/material_ui-*
for patch in "$PILI"/lib/scripts/material/*.patch; do
  git apply "$patch"
done
```

注意：`LocalHistoryEntry` 没有 `popGestureEnabled` 参数，需手动删掉 material_ui scaffold.dart 中的 `popGestureEnabled: true,` 行。

### 编译
```bash
cd <仓库路径>
fvm use 3.47.4
fvm flutter pub get
fvm flutter build macos --release
```
产物：`build/macos/Build/Products/Release/PiliPlus.app`

### 不要用 master channel
Flutter master（3.48.0）的内部 API 和 PiliPlus 不兼容（`OverridingTextStyleTextSpanUtils`、`WidgetSpan.rawText` 等），必须用 3.47.4 stable。

## 短视频功能文件
- `lib/http/api.dart` — 新增 `storyFeed = /x/v2/feed/index/story`
- `lib/http/video.dart` — 新增 `storyFeedList()` 方法
- `lib/pages/short_video/controller.dart` — GetX Controller
- `lib/pages/short_video/view.dart` — PageView 上下滑播放器
- `lib/models/common/home_tab_type.dart` — 新增 `short('短视频')` tab

## 已知问题
- release 模式看不到 print 输出
- `videoControllers` 必须用 `RxMap`，否则 Obx 不 rebuild
- 已关闭自动更新检查（main/controller.dart 中注释掉了 `Update.checkUpdate()`）

## 致命踩坑：media_kit_video 用 stub 导致 MissingPluginException

**症状**：自己 `Player.create()` 成功，但 `VideoController.create()` 抛
`MissingPluginException(No implementation found for method VideoOutputManager.Create on channel com.alexmercerind/media_kit_video)`。
PiliPlus 自己的长视频播放器却正常。

**根因**：PiliPlus fork 的 `My-Responsitories/media-kit` 仓库里，
`media_kit_video/macos/media_kit_video/Package.swift` 有个 `hasLibs` 检测——
它在相对路径 `../media_kit_libs_macos_video` 找 mpv 二进制包。
找不到就编译 **stub 版本**（空 `register()`，不注册任何 method handler）。

仓库实际目录结构：
```
media-kit/
├── media_kit_video/
│   └── macos/media_kit_video/Package.swift   ← 找 ../media_kit_libs_macos_video
└── libs/macos/
    └── media_kit_libs_macos_video/           ← 实际在这，../../../libs/macos/
```

**修复**（已做，重新 clone 后需重做）：
1. `pubspec.yaml` 的 `dependency_overrides` 里必须加：
   ```yaml
   media_kit_libs_macos_video:
     git:
       url: https://github.com/My-Responsitories/media-kit.git
       path: libs/macos/media_kit_libs_macos_video
       ref: upstream
   ```
2. 在 pub-cache 里建 symlink：
   ```bash
   cd ~/.pub-cache/git/media-kit-*/media_kit_video/macos
   ln -sf ../../../libs/macos/media_kit_libs_macos_video media_kit_libs_macos_video
   ```
3. 清 SwiftPM 缓存后重编：`rm -rf ~/Library/Caches/org.swift.swiftpm/`
   然后 `xcodebuild -resolvePackageDependencies`（需走 7890 代理下 mpv 二进制），再 `fvm flutter build macos --release`。

**验证**：终端日志出现 `VideoOutput: enableHardwareAcceleration: true` +
`TextureGL: resize: 1920.0x1080.0` = 插件正常工作。

## 其他踩坑
- mpv 播放 B 站视频必须加请求头：
  `player.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl)`
  否则 mpv 报 `Failed to open ...`（CDN 拒绝无 UA 的请求）。
- `kill -9 $(pgrep -f "PiliPlus.app")` 杀进程，`pkill` 无效。
- 不要往 `/Applications` 拷贝（会导致 Spotlight 索引出两个 PiliPlus），直接从 build 目录 open。
- macOS Sandbox 下 `File('/Users/user2/Documents/xxx')` 会被重定向到
  `~/Library/Containers/com.example.piliplus/Data/Documents/`。
