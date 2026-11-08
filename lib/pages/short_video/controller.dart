import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/video.dart';
import 'package:PiliPlus/http/sponsor_block.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/user.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/models/video/play/url.dart';
import 'package:PiliPlus/pages/common/common_controller.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ShortVideoController extends GetxController with ScrollOrRefreshMixin {
  /// Called when async filter skip needs to move the PageView
  void Function(int)? jumpToPage;

  @override
  void onInit() {
    super.onInit();
    _filterLoadFuture = _loadFilterConfig();
    loadFirst();
  }
  void _dbg(String msg) {
    try {
      stderr.writeln('[ShortVideo] $msg');
    } catch (_) {}
  }

  @override
  final ScrollController scrollController = ScrollController();

  final RxList items = [].obs;
  final RxBool isLoading = false.obs;
  final RxBool isLoadingMore = false.obs;
  final RxInt currentIndex = 0.obs;
  final RxBool isVideoReady = false.obs;
  // 视频层是否可以 revealed（封面撤掉）。isVideoReady 表示 mpv 已开始播放，
  // 但 Android 硬解下 SurfaceTexture 还要经历一次 resize，首帧可能以错误
  // 尺寸/位置闪现（缩小的画面闪一下）。videoReveal 在播放稳定、rect 正常
  // 之后再置 true，让封面多盖住这几十毫秒的脏帧。
  final RxBool videoReveal = false.obs;
  final RxBool hasStarted = false.obs;
  final RxBool hasController = false.obs;
  final RxDouble position = 0.0.obs;
  final RxDouble duration = 0.0.obs;

  dynamic _lastItem;
  // 3-player pool: each slot has its own Player + VideoController
  final List<Player> _players = [];
  final List<VideoController> _videoControllers = [];
  final Map<int, int> _slotForIndex = {}; // item index -> slot number
  int _currentSlot = -1;
  VideoController? get videoController =>
      _currentSlot >= 0 && _currentSlot < _videoControllers.length
          ? _videoControllers[_currentSlot]
          : null;
  List<VideoController> get allVideoControllers => _videoControllers;
  StreamSubscription? _playingSub;
  StreamSubscription? _bufferingSub;
  Timer? _positionTimer;
  Timer? _revealTimer;
  /// surface（SurfaceTexture buffer）被 resize 到视频真实尺寸的时刻。
  DateTime? _surfaceReadyAt;
  /// open 之前 slot 的 rect（上一条视频的尺寸）。凡与其相同的 rect
  /// 都视为旧视频残留，不采纳、不算 surface 就绪。
  Rect? _rectBeforeLoad;
  /// surface 就绪后再等多久才允许视频上屏（跨 2~3 帧渲染）。
  static const int _revealSettleMs = 180;
  /// 兜底上限：无论 rect 是否就绪，播放开始这么久后一律放行。
  static const int _revealMaxWaitMs = 2500;
  StreamSubscription? _widthSub;
  StreamSubscription? _heightSub;
  final RxnInt videoWidth = RxnInt();
  final RxnInt videoHeight = RxnInt();
  /// Pre-resolved cover aspect ratios (url -> w/h), so the cover layer
  /// renders with the correct ratio (and position) before video size arrives.
  final RxMap<String, double> coverAr = RxMap<String, double>();
  /// [startMs, endMs, categoryColor] segments marked by SponsorBlock
  final RxList<List<dynamic>> blockSegments = <List<dynamic>>[].obs;
  bool _isLoadingVideo = false;
  int _loadGeneration = 0;
  bool _firstOpen = true;
  /// Cache pre-fetched video URLs: bvid -> [videoUrl, audioUrl]
  final Map<String, List<String?>> _urlCache = {};

  Set<String> _blockedBvids = {};
  Set<int> _blockedOwnerMids = {};
  List<String> _newsKeywords = [];
  List<String> _titleKeywords = [];
  List<String> _blockedMusicKeywords = [];
  Future? _filterLoadFuture;

  /// Load filter config from assets and external override
  Future<void> _loadFilterConfig() async {
    try {
      // Try external override first (can be updated via adb push without rebuild)
      Map<String, dynamic>? jsonMap;
      try {
        final extDir = Directory('/sdcard/Android/data/com.example.piliplus/files');
        final extFile = File('${extDir.path}/short_video_filter.json');
        if (await extFile.exists()) {
          final str = await extFile.readAsString();
          jsonMap = json.decode(str);
          _dbg('Loaded filter from external override');
        }
      } catch (_) {}
      // Fall back to bundled asset
      if (jsonMap == null) {
        final str = await rootBundle.loadString('assets/short_video_filter.json');
        jsonMap = json.decode(str);
        _dbg('Loaded filter from bundled asset');
      }
      final m = jsonMap!;
      _blockedBvids = (m['blockedBvids'] as List?)?.map((e) => e.toString()).toSet() ?? {};
      _blockedOwnerMids = (m['blockedOwnerMids'] as List?)?.map((e) {
        if (e is int) return e;
        if (e is Map) return (e['mid'] as num).toInt();
        return 0;
      }).where((e) => e > 0).toSet() ?? {};
      _newsKeywords = _extractWords(m['newsKeywords']);
      _titleKeywords = _extractWords(m['titleKeywords']);
      _blockedMusicKeywords = _extractWords(m['blockedMusicKeywords']);
      // merge personal keywords from local storage
      _newsKeywords.addAll(GStorage.localCache.get(LocalCacheKey.svNewsKeywords, defaultValue: <String>[]));
      _titleKeywords.addAll(GStorage.localCache.get(LocalCacheKey.svTitleKeywords, defaultValue: <String>[]));
      _blockedMusicKeywords.addAll(GStorage.localCache.get(LocalCacheKey.svMusicKeywords, defaultValue: <String>[]));
      _dbg('Filter loaded: ${_blockedBvids.length} bvids, ${_blockedOwnerMids.length} mids, ${_newsKeywords.length} keywords');
    } catch (e) {
      _dbg('Filter load failed: $e');
    }
  }


  List<String> _extractWords(dynamic list) {
    if (list is! List) return [];
    return list.map((e) {
      if (e is String) return e;
      if (e is Map) return (e['word'] ?? '').toString();
      return '';
    }).where((e) => e.isNotEmpty).toList();
  }

  /// Check if video uses a blocked song via player/v2 bgm_info
  Future<bool> _isBlockedMusic(String bvid, int cid) async {
    if (_blockedMusicKeywords.isEmpty) return false;
    try {
      final resp = await Request().get(
        'https://api.bilibili.com/x/player/v2',
        queryParameters: {'bvid': bvid, 'cid': cid},
      );
      final data = resp.data?['data'];
      final bgm = data?['bgm_info'];
      if (bgm != null) {
        final title = (bgm['music_title'] ?? bgm['title'] ?? bgm['name'] ?? '').toString();
        for (final kw in _blockedMusicKeywords) {
          if (title.contains(kw)) {
            _dbg('BLOCKED by music: $title');
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  bool _isBlocked(dynamic item) {
    if (item.bvid != null && _blockedBvids.contains(item.bvid)) return true;
    final mid = item.owner?.mid;
    if (mid != null && _blockedOwnerMids.contains(mid)) return true;
    // 关键词匹配：UP 主昵称包含新闻类关键词就屏蔽
    final ownerName = item.owner?.name ?? item.ownerName;
    if (ownerName != null) {
      for (final kw in _newsKeywords) {
        if (ownerName.contains(kw)) return true;
      }
    }
    // 标题关键词：吃流量/猎奇/冲突类
    final title = item.title as String?;
    if (title != null) {
      for (final kw in _titleKeywords) {
        if (title.contains(kw)) return true;
      }
      // 也检查音乐关键词（有些视频直接把歌名写标题里）
      for (final kw in _blockedMusicKeywords) {
        if (title.contains(kw)) return true;
      }
    }
    return false;
  }

  /// Tag keywords that indicate news-style content
  static const List<String> _tagKeywords = [
    '新闻', '热点', '社会', '现场', '时事', '资讯',
    '突发', '民生', '一线', '直击',
  ];

  List _filter(List raw) {
    return raw.where((i) => !_isBlocked(i)).toList();
  }

  @override
  Future<void> onRefresh() => loadFirst();

  /// Fetch story feed repeatedly, skipping blocked items, until we have
  /// `count` unblocked videos (or ran `maxAttempts` requests). The cursor
  /// always advances with the raw last item of each response, so blocked
  /// batches don't stall the feed.
  Future<List> _fetchUnblocked({String? bvid, int count = 10, int maxAttempts = 5}) async {
    final collected = <dynamic>[];
    for (var attempt = 0; attempt < maxAttempts && collected.length < count; attempt++) {
      final result = await VideoHttp.storyFeedList(bvid: bvid);
      if (result case Success(:final response)) {
        if (response.isEmpty) break;
        bvid = response.last.bvid; // advance cursor with the raw last item
        for (final item in _filter(response)) {
          final b = item.bvid;
          if (b != null && collected.any((e) => e.bvid == b)) continue;
          collected.add(item);
        }
      } else {
        break;
      }
    }
    return collected;
  }

  Future<void> _resolveCoverSizes(Iterable<dynamic> items) async {
    for (final it in items) {
      final cover = it.cover;
      if (cover is String && cover.isNotEmpty && !coverAr.containsKey(cover)) {
        _resolveCoverSize(cover);
      }
    }
  }

  Future<void> _resolveCoverSize(String url) async {
    try {
      final stream = NetworkImage(url).resolve(ImageConfiguration.empty);
      final completer = Completer<ImageInfo>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (info, _) {
          if (!completer.isCompleted) completer.complete(info);
        },
        onError: (e, s) {
          if (!completer.isCompleted) completer.completeError(e);
        },
      );
      stream.addListener(listener);
      final info = await completer.future;
      stream.removeListener(listener);
      if (info.image.width > 0 && info.image.height > 0) {
        coverAr[url] = info.image.width / info.image.height;
      }
    } catch (_) {}
  }

  Future<void> loadFirst() async {
    await _filterLoadFuture;
    isLoading.value = true;
    _lastItem = null;
    items.clear();
    final fresh = await _fetchUnblocked(count: 12);
    if (fresh.isNotEmpty) {
      items.assignAll(fresh);
      _lastItem = items.last;
      _resolveCoverSizes(fresh);
    }
    isLoading.value = false;
    if (hasStarted.value && items.isNotEmpty) {
      playVideoAt(0);
    }
  }

  /// Start playing video at given index. Called when user first interacts
  /// with the short video tab (tap, scroll, arrow key).
  void pauseAll() {
    for (final p in _players) { p.pause(); }
  }

  void setRate(double rate) {
    if (_currentSlot >= 0) { try { _players[_currentSlot].setRate(rate); } catch (_) {} }
  }

  void ensureStarted() {
    if (hasStarted.value) return;
    hasStarted.value = true;
    if (items.isNotEmpty) {
      playVideoAt(0);
    }
  }

  Future<void> loadMore() async {
    if (isLoadingMore.value) return;
    isLoadingMore.value = true;
    try {
      final fresh = await _fetchUnblocked(bvid: _lastItem?.bvid, count: 8);
      if (fresh.isNotEmpty) {
        final known = items.map((e) => e.bvid).toSet();
        items.addAll(fresh.where((e) => !known.contains(e.bvid)));
        if (items.isNotEmpty) {
          _lastItem = items.last;
        }
        _resolveCoverSizes(fresh);
        // Pre-check the newly appended tail so swiping there is seamless
        _preDeepCheck(items.length - 1);
        _preDeepCheck(items.length - 2);
      }
    } finally {
      isLoadingMore.value = false;
    }
  }

  Map<String, dynamic> getItemSummary(int index) {
    if (index < 0 || index >= items.length) return {};
    final item = items[index];
    return {
      'bvid': item.bvid,
      'aid': item.aid,
      'cid': item.cid,
      'title': item.title,
      'ownerName': item.owner?.name,
      'ownerMid': item.owner?.mid,
      'cover': item.cover,
      'duration': item.duration,
      'goto': item.goto,
    };
  }

  /// 延迟撤掉封面：播放已开始后再等一小段，并确认 VideoController 的
  /// 输出矩形已就绪（>1px，即 native 侧已完成 surface resize）。
  /// 这样用户永远看不到硬解首帧以错误尺寸/位置闪现的脏帧。
  void _scheduleVideoReveal(int gen) {
    _revealTimer?.cancel();
    final startedAt = DateTime.now();
    void attempt() {
      if (gen != _loadGeneration) return;
      if (videoReveal.value) return;
      final slot = _currentSlot;
      final r = (slot >= 0 && slot < _videoControllers.length)
          ? _videoControllers[slot].rect.value
          : null;
      var surfaceReady = r != null && r.width > 1 && r.height > 1;
      // rect 会经历一个 mpv 重建输出过程中的"错误中间值"（实测某 9:16 视频
      // 短暂上报约 0.26 的宽高比），用接口返回的真实宽高做交叉校验：
      // 比例对不上就视为未就绪，封面继续盖着，直到 rect 稳定为正确值。
      if (surfaceReady &&
          currentIndex.value >= 0 &&
          currentIndex.value < items.length) {
        final item = items[currentIndex.value];
        if (item.videoWidth != null &&
            item.videoHeight != null &&
            item.videoWidth! > 0 &&
            item.videoHeight! > 0) {
          final dar = item.videoWidth! / item.videoHeight!;
          final rr = r!.width / r.height;
          if ((rr - dar).abs() / dar > 0.05) surfaceReady = false;
        }
      }
      if (!surfaceReady) {
        _surfaceReadyAt = null;
      } else {
        _surfaceReadyAt ??= DateTime.now();
      }
      // surface 被 resize 到视频真实尺寸之后，mpv 还要在新 vo 上真正渲染出
      // 至少一帧，Flutter 上屏才会拿到正确尺寸的 buffer。在此之前上屏拿到
      // 的是 resize 前/被 clear 的旧 buffer，会被 Texture 拉伸成畸形画面
      // （9:16 压成 3:16、或缩小挤在角落）。所以从 surface 就绪起再等
      // _revealSettleMs，跨过 2~3 帧再撤封面。
      final settleMs = _surfaceReadyAt == null
          ? 0
          : DateTime.now().difference(_surfaceReadyAt!).inMilliseconds;
      if (surfaceReady && settleMs >= _revealSettleMs) {
        videoReveal.value = true;
        return;
      }
      // 兜底：极端情况（rect 迟迟不来）也不能让封面无限盖着
      if (DateTime.now().difference(startedAt).inMilliseconds >= _revealMaxWaitMs) {
        videoReveal.value = true;
        return;
      }
      _revealTimer = Timer(const Duration(milliseconds: 50), attempt);
    }

    attempt();
  }

  Future<void> playVideoAt(int index) async {
    if (index < 0 || index >= items.length) return;
    _loadGeneration++;
    final gen = _loadGeneration;
    currentIndex.value = index;
    isVideoReady.value = false;
    videoReveal.value = false;
    _surfaceReadyAt = null;
    videoWidth.value = null;
    videoHeight.value = null;

    // Deep check (BGM/tags) BEFORE presenting. Blocked videos are skipped
    // here instead of mid-play, so the user never sees a video being yanked.
    final deepBlocked = await _ensureDeepChecked(index, timeout: const Duration(seconds: 3));
    if (gen != _loadGeneration) return;
    if (deepBlocked) {
      _dbg('DEEP-SKIP index=$index');
      if (index + 1 < items.length) {
        jumpToPage?.call(index + 1);
      } else {
        loadMore();
      }
      return;
    }
    _logWatched(items[index]);
    // Immediately stop old video to clear stale frame
    if (_players.isNotEmpty) {
      try { _players.first.stop(); } catch (_) {}
    }

    // Wait for previous load
    while (_isLoadingVideo) {
      await Future.delayed(const Duration(milliseconds: 50));
      if (gen != _loadGeneration) return;
    }
    _isLoadingVideo = true;

    try {
      // Ensure 3 player slots exist
      if (_players.length < 1) {
        MediaKit.ensureInitialized();
        for (int i = 0; i < 1; i++) {
          final p = await Player.create(
            configuration: const PlayerConfiguration(logLevel: .error, title: 'PiliPlus SV', options: {'background': 'white'}),
          );
          p.setMediaHeader(userAgent: BrowserUa.pc, referer: HttpString.baseUrl);
          await Future.delayed(const Duration(milliseconds: 200));
          final vc = await VideoController.create(p, configuration: const VideoControllerConfiguration(enableHardwareAcceleration: true, hwdec: 'auto-safe'));
          _players.add(p);
          _videoControllers.add(vc);
        }
        hasController.value = true;
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Find which slot already has this index
      int? slot = _slotForIndex[index];
      // Single-player mode: the only slot may have been overwritten by a
      // later playVideoAt since, so a cached mapping does NOT guarantee the
      // media in it belongs to this index. Always reload from scratch.
      if (_players.length <= 1) {
        slot = null;
      }

      // If not loaded, find recyclable slot (furthest from current)
      if (slot == null) {
        slot = _findRecyclableSlot(index);
        // 记录 open 之前该 slot 的 rect：open 后 rect 仍是这个旧值时，
        // 说明它属于上一条视频，绝不能当作当前视频的尺寸（否则布局
        // 会用旧视频的宽高比，新视频首帧被塞进错误比例的框里）。
        _rectBeforeLoad = _videoControllers[slot].rect.value;
        final item = items[index];
        if (item.cid == null || item.bvid == null) return;

        String? videoUrl;
        String? audioUrl;
        final cached = _urlCache[item.bvid];
        if (cached != null) {
          videoUrl = cached[0];
          audioUrl = cached[1];
        } else {
          final result = await VideoHttp.videoUrl(bvid: item.bvid!, cid: item.cid!, qn: 64, tryLook: true, videoType: VideoType.ugc);
          if (gen != _loadGeneration) return;
          if (result case Success(:final response)) {
            final model = response as PlayUrlModel;
            if (model.dash?.video?.isNotEmpty == true) {
              final videos = model.dash!.video!;
              final h264 = videos.where((v) => v.codecs?.startsWith('avc1') ?? false).toList();
              videoUrl = (h264.isNotEmpty ? h264.first : videos.first).baseUrl;
            }
            if (model.dash?.audio?.isNotEmpty == true) {
              audioUrl = model.dash!.audio!.first.baseUrl;
            }
          }
        }
        if (videoUrl == null) {
          if (index + 1 < items.length) {
            jumpToPage?.call(index + 1);
          } else { loadMore(); }
          return;
        }

        String mediaUrl = videoUrl;
        if (audioUrl != null && audioUrl.isNotEmpty) {
          mediaUrl = 'edl://!no_chapters;%${videoUrl.length}%$videoUrl;!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';
        }

        final p = _players[slot];
        await p.setVolume(0);
        await p.stop();
        await p.open(Media(mediaUrl), play: false);
        // Wait longer for first frame to decode
        await Future.delayed(const Duration(milliseconds: 800));

        // Update slot mapping
        _slotForIndex.removeWhere((k, v) => v == slot);
        _slotForIndex[index] = slot;
      }

      if (gen != _loadGeneration) return;

      // Pause all other slots, play the target
      for (int i = 0; i < _players.length; i++) {
        if (i == slot) continue;
        await _players[i].pause();
        await _players[i].setVolume(0);
      }

      _currentSlot = slot;
      final p = _players[slot];

      // Wire up playing listener BEFORE play() so the playing event is never
      // missed. If we play() first and attach the listener after, the event
      // can fire early and volume stays 0 forever (only pause+resume escapes,
      // because it re-emits the event). An async setVolume(0) racing with
      // setVolume(100) can also leave the volume at 0.
      _playingSub?.cancel();
      _playingSub = p.stream.playing.listen((playing) {
        if (playing) {
          isVideoReady.value = true;
          p.setVolume(100);
          WakelockPlus.enable();
          _scheduleVideoReveal(gen);
        }
      });
      // Wire up position/duration listeners to current player
      p.stream.position.listen((pos) { position.value = pos.inMilliseconds.toDouble(); });
      p.stream.duration.listen((dur) { duration.value = dur.inMilliseconds.toDouble(); });
      // Immediately read current state (first video may have already emitted before listener attached)
      position.value = p.state.position.inMilliseconds.toDouble();
      duration.value = p.state.duration.inMilliseconds.toDouble();

      // Now start playback (volume is already 0 from the pre-open setVolume(0))
      await p.play();

      // Track video dimensions from VideoController rect
      final vc = _videoControllers[slot];
      // Read current value immediately (don't wait for listener)
      final curRect = vc.rect.value;
      if (curRect != null) {
        videoWidth.value = curRect.width.toInt();
        videoHeight.value = curRect.height.toInt();
      }
      vc.rect.addListener(() {
        final r = vc.rect.value;
        if (r != null) {
          videoWidth.value = r.width.toInt();
          videoHeight.value = r.height.toInt();
        }
      });
      // Poll position as fallback (Android stream may not fire on first entry)
      _positionTimer?.cancel();
      _positionTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_currentSlot >= 0 && _currentSlot < _players.length) {
          final ps = _players[_currentSlot].state;
          position.value = ps.position.inMilliseconds.toDouble();
          duration.value = ps.duration.inMilliseconds.toDouble();
          // Fallback: if position is advancing, video is actually playing
          if (!isVideoReady.value && ps.position.inMilliseconds > 500) {
            isVideoReady.value = true;
            _players[_currentSlot].setVolume(100);
            WakelockPlus.enable();
            _scheduleVideoReveal(gen);
          }
        }
      });
      p.stream.position.listen((pos) { position.value = pos.inMilliseconds.toDouble(); });
      p.stream.duration.listen((dur) { duration.value = dur.inMilliseconds.toDouble(); });
      _fetchBlockSegments();
      // Pre-check the next two videos in background so swiping is seamless
      _preDeepCheck(index + 1);
      _preDeepCheck(index + 2);

      // Pre-load next-next into the recycled slot
      _prefetchUrl(index + 1);
      _prefetchUrl(index + 2);
      _prefetchUrl(index + 3);
      _prefetchUrl(index - 1);

      // Auto-preload adjacent media into free slots
      // NOTE: single-player mode — preloading would recycle the current
      // playing slot and overwrite it with another video, causing title/video
      // mismatch. Only meaningful with multiple player instances.
      if (_players.length > 1) {
        _preloadAdjacent(index);
      }
    } catch (e) {
      _dbg('ERROR: $e');
    } finally {
      _isLoadingVideo = false;
    }
  }

  int _findRecyclableSlot(int targetIndex) {
    // If a slot is unassigned, use it
    for (int i = 0; i < _players.length; i++) {
      if (!_slotForIndex.containsValue(i)) return i;
    }
    // Otherwise recycle the slot furthest from target
    int bestSlot = 0;
    int bestDist = -1;
    _slotForIndex.forEach((idx, slot) {
      final d = (idx - targetIndex).abs();
      if (d > bestDist) { bestDist = d; bestSlot = slot; }
    });
    return bestSlot;
  }

  Future<void> _preloadAdjacent(int currentIdx) async {
    // Preload next videos, recycling oldest slot if needed
    for (final offset in [1, -1, 2, 3]) {
      final target = currentIdx + offset;
      if (target < 0 || target >= items.length) continue;
      if (_slotForIndex.containsKey(target)) continue;
      // Find free slot, or recycle oldest if all occupied
      int? freeSlot;
      for (int i = 0; i < _players.length; i++) {
        if (!_slotForIndex.containsValue(i)) { freeSlot = i; break; }
      }
      freeSlot ??= _findRecyclableSlot(target);
      final item = items[target];
      if (item.bvid == null || item.cid == null) continue;
      String? videoUrl;
      String? audioUrl;
      final cached = _urlCache[item.bvid];
      if (cached != null) {
        videoUrl = cached[0]; audioUrl = cached[1];
      } else {
        try {
          final result = await VideoHttp.videoUrl(bvid: item.bvid!, cid: item.cid!, qn: 64, tryLook: true, videoType: VideoType.ugc);
          if (result case Success(:final response)) {
            final model = response as PlayUrlModel;
            if (model.dash?.video?.isNotEmpty == true) {
              final videos = model.dash!.video!;
              final h264 = videos.where((v) => v.codecs?.startsWith('avc1') ?? false).toList();
              videoUrl = (h264.isNotEmpty ? h264.first : videos.first).baseUrl;
            }
            if (model.dash?.audio?.isNotEmpty == true) audioUrl = model.dash!.audio!.first.baseUrl;
          }
        } catch (_) {}
      }
      if (videoUrl == null) continue;
      String mediaUrl = videoUrl;
      if (audioUrl != null && audioUrl.isNotEmpty) {
        mediaUrl = 'edl://!no_chapters;%${videoUrl.length}%$videoUrl;!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';
      }
      try {
        final p = _players[freeSlot];
        await p.setVolume(0);
        await p.open(Media(mediaUrl), play: false);
        _slotForIndex.removeWhere((k, v) => v == freeSlot);
        _slotForIndex[target] = freeSlot;
      } catch (_) {}
    }
  }

  /// Deep-check results: item index -> blocked (BGM or tag hit).
  final Map<int, bool> _deepBlocked = {};
  final Set<int> _deepChecking = {};
  /// Bumped on every completed deep check so the view can rebuild.
  final RxInt deepCheckVersion = 0.obs;

  /// Synchronous query for the view: has this index finished deep check?
  bool isDeepChecked(int index) => _deepBlocked.containsKey(index);

  /// Check BGM + tags of items[index]. Returns true if blocked.
  /// Cache hit returns immediately; in-flight waits; otherwise checks now.
  /// Failures/timeouts are treated as pass (never block on uncertainty).
  Future<bool> _ensureDeepChecked(int index, {Duration timeout = const Duration(seconds: 2)}) async {
    if (index < 0 || index >= items.length) return false;
    final cached = _deepBlocked[index];
    if (cached != null) return cached;
    if (_deepChecking.contains(index)) {
      final deadline = DateTime.now().add(timeout);
      while (_deepChecking.contains(index) && !_deepBlocked.containsKey(index)) {
        await Future.delayed(const Duration(milliseconds: 50));
        if (DateTime.now().isAfter(deadline)) return false;
      }
      return _deepBlocked[index] ?? false;
    }
    _deepChecking.add(index);
    try {
      final item = items[index];
      final bvid = item.bvid;
      final cid = item.cid;
      bool blocked = false;
      if (bvid != null && cid != null) {
        final results = await Future.wait([
          _isBlockedMusic(bvid, cid),
          _hasBlockedTag(bvid, cid),
        ]);
        blocked = results[0] || results[1];
      }
      _deepBlocked[index] = blocked;
      deepCheckVersion.value++;
      if (blocked) _logDeepSkip(index);
      return blocked;
    } finally {
      _deepChecking.remove(index);
    }
  }

  /// Background pre-check (fire and forget).
  void _preDeepCheck(int index) {
    if (index < 0 || index >= items.length) return;
    if (_deepBlocked.containsKey(index)) return;
    _ensureDeepChecked(index);
  }

  /// Check whether video tags contain any news-style keyword.
  Future<bool> _hasBlockedTag(String bvid, int cid) async {
    try {
      final result = await UserHttp.videoTags(bvid: bvid, cid: cid);
      if (result is Success<List<dynamic>>) {
        final tags = (result as Success<List<dynamic>>).response;
        if (tags == null) return false;
        for (final tag in tags) {
          final tagName = tag.tagName ?? '';
          for (final kw in _tagKeywords) {
            if (tagName.contains(kw)) return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  void _logDeepSkip(int index) {
    try {
      final item = items[index];
      final now = DateTime.now().toIso8601String();
      final ownerName = item.owner?.name ?? item.ownerName ?? '';
      final title = item.title ?? '';
      final bvid = item.bvid ?? '';
      final file = File('/sdcard/Android/data/com.example.piliplus/files/short_video_watch.log');
      file.writeAsStringSync('[$now] [DEEP_SKIP] $bvid | $ownerName | $title\n', mode: FileMode.append);
    } catch (_) {}
  }

  void _checkBlockedMusic(int index) async {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    if (item.bvid == null || item.cid == null) return;
    final myGen = _loadGeneration;
    final blocked = await _isBlockedMusic(item.bvid!, item.cid!);
    // User may have swiped away during async check
    if (myGen != _loadGeneration) return;
    if (blocked && currentIndex.value == index) {
      _logWatched(item);
      if (index + 1 < items.length) {
        jumpToPage?.call(index + 1);
      } else { loadMore(); }
    }
  }

  void togglePlay() {
    if (_currentSlot < 0) return;
    final p = _players[_currentSlot];
    if (p.state.playing) { p.pause(); } else { p.play(); }
  }

  void seekRelative(int seconds) {
    if (_currentSlot < 0) return;
    final p = _players[_currentSlot];
    final pos = p.state.position;
    final dur = p.state.duration;
    var newMs = pos.inMilliseconds + seconds * 1000;
    if (newMs < 0) newMs = 0;
    if (newMs > dur.inMilliseconds) newMs = dur.inMilliseconds;
    p.seek(Duration(milliseconds: newMs));
  }

  void seekTo(double fraction) {
    if (_currentSlot < 0) return;
    final p = _players[_currentSlot];
    final dur = p.state.duration;
    if (dur.inMilliseconds == 0) return;
    p.seek(Duration(milliseconds: (fraction * dur.inMilliseconds).round()));
  }

  void openComment() {
    if (currentIndex.value < 0 || currentIndex.value >= items.length) return;
    final item = items[currentIndex.value];
    if (item.bvid == null || item.cid == null) return;
    // Pause short video before navigating to detail page
    if (_currentSlot >= 0) _players[_currentSlot].pause();
    PageUtils.toVideoPage(
      bvid: item.bvid!,
      cid: item.cid!,
      cover: item.cover,
      title: item.title,
    );
  }

  /// Pre-fetch video URL for next item in background
  void _prefetchUrl(int index) async {
    if (index < 0 || index >= items.length) return;
    final item = items[index];
    if (item.bvid == null || item.cid == null) return;
    if (_urlCache.containsKey(item.bvid)) return; // already cached
    try {
      final result = await VideoHttp.videoUrl(
        bvid: item.bvid!,
        cid: item.cid!,
        qn: 64,
        tryLook: true,
        videoType: VideoType.ugc,
      );
      if (result case Success(:final response)) {
        final model = response as PlayUrlModel;
        String? videoUrl;
        String? audioUrl;
        if (model.dash?.video?.isNotEmpty == true) {
          final videos = model.dash!.video!;
          final h264 = videos.where((v) => v.codecs?.startsWith('avc1') ?? false).toList();
          final chosen = h264.isNotEmpty ? h264.first : videos.first;
          videoUrl = chosen.baseUrl;
        }
        if (model.dash?.audio?.isNotEmpty == true) {
          audioUrl = model.dash!.audio!.first.baseUrl;
        }
        if (videoUrl != null) {
          _urlCache[item.bvid!] = [videoUrl, audioUrl];
        }
      }
    } catch (_) {}
  }

  /// Append watched video metadata to log file
  void _logWatched(dynamic item) {
    try {
      final now = DateTime.now().toIso8601String();
      final ownerName = item.owner?.name ?? item.ownerName ?? '';
      final title = item.title ?? '';
      final bvid = item.bvid ?? '';
      final line = '[$now] $bvid | $ownerName | $title\n';
      final file = File('/sdcard/Android/data/com.example.piliplus/files/short_video_watch.log');
      file.writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {}
  }

  /// Fetch sponsor block segments for current video
  void _fetchBlockSegments() async {
    blockSegments.clear();
    try {
      final item = items.isNotEmpty && currentIndex.value >= 0 && currentIndex.value < items.length
          ? items[currentIndex.value]
          : null;
      if (item == null) return;
      final bvid = item.bvid;
      final cid = item.cid;
      if (bvid == null || cid == null) return;
      final result = await SponsorBlock.getSkipSegments(bvid: bvid, cid: cid);
      if (result is Success<List<dynamic>>) {
        final list = (result as Success<List<dynamic>>).response;
        blockSegments.value = list
            .map((e) {
              final cat = SegmentType.values.firstWhere(
                (t) => t.name == e.category,
                orElse: () => SegmentType.sponsor,
              );
              return [e.segment[0] as int, e.segment[1] as int, cat.color.toARGB32()];
            })
            .where((s) => s[1] > s[0])
            .toList();
      }
    } catch (_) {}
  }

  /// Fetch video tags and check if any indicate news content
  void _checkVideoTags(int index) async {
    try {
      if (index < 0 || index >= items.length) return;
      final item = items[index];
      if (item.bvid == null || item.cid == null) return;
      final result = await UserHttp.videoTags(
        bvid: item.bvid!,
        cid: item.cid,
      );
      if (result is Success<List<dynamic>>) {
        final tags = (result as Success<List<dynamic>>).response;
        if (tags == null) return;
        for (final tag in tags) {
          final tagName = tag.tagName ?? '';
          for (final kw in _tagKeywords) {
            if (tagName.contains(kw)) {
              _dbg('Tag match: $tagName contains "$kw", skipping');
              // Log the skip
              try {
                final now = DateTime.now().toIso8601String();
                final ownerName = item.owner?.name ?? item.ownerName ?? '';
                final title = item.title ?? '';
                final bvid = item.bvid ?? '';
                final file = File('/sdcard/Android/data/com.example.piliplus/files/short_video_watch.log');
                file.writeAsStringSync('[$now] [TAG_SKIP:$tagName] $bvid | $ownerName | $title\n', mode: FileMode.append);
              } catch (_) {}
              // Auto-skip to next
              if (index + 1 < items.length) {
                jumpToPage?.call(index + 1);
                playVideoAt(index + 1);
              }
              return;
            }
          }
        }
      }
    } catch (_) {}
  }

  @override
  void onClose() {
    WakelockPlus.disable();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _widthSub?.cancel();
    _heightSub?.cancel();
    _revealTimer?.cancel();
    for (final p in _players) { p.dispose(); }
    super.onClose();
  }
}
