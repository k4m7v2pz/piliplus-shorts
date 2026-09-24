# PiliPlus — 短视频改版

基于上游 [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus) 的 fork，新增竖屏短视频 feed。

## 改了什么

在 PiliPlus 基础上新增了竖屏沉浸式短视频 feed（上下滑刷视频）：

- 新 tab「短视频」，数据源为 `app.bilibili.com/x/v2/feed/index/story`
- PageView 竖屏翻页，鼠标滚轮一格即切
- media_kit 播放器，DASH 音视频用 edl:// 合并
- 右上角「复制信息」按钮，一键复制当前视频元数据
- 观看历史自动记录到 `~/Documents/piliplus_shortvideo_log.jsonl`

## 编译

详见 [AGENTS.md](AGENTS.md) 和 [test.rvs](test.rvs)。

简要：需要 FVM Flutter 3.47.4 + 打补丁（见 AGENTS.md），走 7890 代理。
`rvs test.rvs` 一键 clean build + 启动。

## 已知问题

- macOS 上必须 `flutter clean` 后编译，incremental build 会丢失 media_kit_video 原生插件链接
- 短视频 MVP：无点赞/评论/收藏、无手势双击、无预加载优化
- 部分新闻号 UP 主昵称为空（B站 API 返回问题）
