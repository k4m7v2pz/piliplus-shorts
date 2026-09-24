import 'dart:convert';
import 'package:PiliPlus/utils/platform_utils.dart';

import 'package:PiliPlus/pages/short_video/controller.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit_video/media_kit_video.dart';

class ShortVideoPage extends StatefulWidget {
  const ShortVideoPage({super.key});

  @override
  State<ShortVideoPage> createState() => _ShortVideoPageState();
}

class _ShortVideoPageState extends State<ShortVideoPage> {
  final ShortVideoController _c = Get.put(ShortVideoController(), permanent: true);
  final PageController _pageController = PageController();
  final FocusNode _focusNode = FocusNode();
  int _currentIndex = 0;
  final ValueNotifier<double> _dragOffset = ValueNotifier(0.0);
  double _scrollAccumulator = 0;
  bool _isAnimating = false;
  double? _dragStartPixels;
  DateTime? _lastJumpTime;

  @override
  void initState() {
    super.initState();
    _c.jumpToPage = _jumpToPage;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    if (index != _currentIndex) {
      _currentIndex = index;
      _dragOffset.value = 0;
      _c.playVideoAt(index);
      if (index >= _c.items.length - 3) {
        _c.loadMore();
      }
    }
  }

  void _goToPage(int index) {
    if (_isAnimating || index < 0 || index >= _c.items.length) return;
    _isAnimating = true;
    _scrollAccumulator = 0;
    _pageController
        .animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    )
        .then((_) {
      _isAnimating = false;
    });
  }

  /// Instant jump (no animation) for keyboard / wheel
  void _jumpToPage(int index) {
    if (index < 0 || index >= _c.items.length) return;
    _scrollAccumulator = 0;
    _pageController.jumpToPage(index);
  }

  void _handleScroll(double deltaDy) {
    _c.ensureStarted();
    if (_isAnimating) return;
    // Cooldown: 500ms after last jump, ignore scroll
    final now = DateTime.now();
    if (_lastJumpTime != null && now.difference(_lastJumpTime!).inMilliseconds < 500) {
      _scrollAccumulator = 0;
      return;
    }
    _scrollAccumulator += deltaDy;
    if (_scrollAccumulator.abs() > 3) {
      _lastJumpTime = now;
      if (_scrollAccumulator > 0) {
        _jumpToPage(_currentIndex + 1);
      } else {
        _jumpToPage(_currentIndex - 1);
      }
      _scrollAccumulator = 0;
    }
  }

  void _copyCurrentVideo() {
    final summary = _c.getItemSummary(_currentIndex);
    if (summary.isEmpty) return;
    Clipboard.setData(ClipboardData(text: const JsonEncoder.withIndent('  ').convert(summary)));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已拷贝: ${summary['ownerName'] ?? ''} - ${summary['title'] ?? ''}'),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
      body: Padding(
        padding: EdgeInsets.only(bottom: Theme.of(context).platform == TargetPlatform.android || Theme.of(context).platform == TargetPlatform.iOS ? 80 + MediaQuery.viewPaddingOf(context).bottom : 0),
        child: Listener(
        onPointerSignal: (signal) {
          if (signal is PointerScrollEvent) {
            _handleScroll(signal.scrollDelta.dy);
          }
        },
        child: PlatformUtils.isMobile
            ? Focus(
                focusNode: _focusNode,
                autofocus: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent || event is KeyRepeatEvent) {
                    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                      _c.ensureStarted();
                      _jumpToPage(_currentIndex + 1);
                      return KeyEventResult.handled;
                    }
                    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                      _c.ensureStarted();
                      _jumpToPage(_currentIndex - 1);
                      return KeyEventResult.handled;
                    }
                  }
                  return KeyEventResult.ignored;
                },
                child: Obx(() {
                  if (_c.isLoading.value && _c.items.isEmpty) {
                    return const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    );
                  }
                  if (_c.items.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('暂无短视频', style: TextStyle(color: Colors.white)),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: _c.loadFirst,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    );
                  }

                  final currentItem = _c.currentIndex.value >= 0 &&
                          _c.currentIndex.value < _c.items.length
                      ? _c.items[_c.currentIndex.value]
                      : null;

                  return NotificationListener<ScrollUpdateNotification>(
                    onNotification: (notification) {
                      _dragOffset.value =
                          notification.metrics.pixels -
                          _currentIndex *
                              notification.metrics.viewportDimension;
                      return false;
                    },
                    child: Stack(
                    children: [
                      PageView.builder(
                        controller: _pageController,
                        scrollDirection: Axis.vertical,
                        itemCount: _c.items.length,
                        physics: const ClampingScrollPhysics(),
                        onPageChanged: _onPageChanged,
                        itemBuilder: (context, index) =>
                            ColoredBox(color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF)),
                      ),
                      // Video layer that follows scroll offset for drag-following
                      Obx(() {
                        final hasC = _c.hasController.value;
                        final ready = _c.isVideoReady.value;
                        if (!hasC || !ready) return const SizedBox();
                        return Positioned.fill(
                          child: ValueListenableBuilder<double>(
                              valueListenable: _dragOffset,
                              builder: (context, offset, child) {
                                return Transform.translate(
                                  offset: Offset(0, -offset),
                                  child: child,
                                );
                              },
                              child: Obx(() {
                                final w = _c.videoWidth.value;
                                final h = _c.videoHeight.value;
                                _c.currentIndex.value;
                                final ar = (w != null && h != null && w > 0 && h > 0) ? w / h : 9.0 / 16.0;
                                final dy = ar > 0.7 ? -MediaQuery.of(context).size.height * 0.15 : 0.0;
                                return IgnorePointer(
                                  child: Transform.translate(
                                    offset: Offset(0, dy),
                                    child: Video(
                                      controller: _c.videoController!,
                                      fit: BoxFit.contain,
                                      fill: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                                      controls: null,
                                      wakelock: false,
                                    ),
                                  ),
                                );
                              }),
                            ),
                        );
                      }),
                      // Cover image - instant show when not ready, fade out when ready
                      Obx(() {
                        final ready = _c.isVideoReady.value;
                        if (!ready) {
                          // Instantly show cover, no fade-in
                          return Positioned.fill(
                            child: Container(
                              color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                              child: (currentItem?.cover != null && _c.currentIndex.value > 0)
                                ? Obx(() {
                                    final w = _c.videoWidth.value;
                                    final h = _c.videoHeight.value;
                                    _c.currentIndex.value;
                                    final cover = Image.network(
                                      currentItem!.cover!,
                                      fit: BoxFit.contain,
                                      errorBuilder: (a, b, c) => const SizedBox(),
                                    );
                                    final ar = (w != null && h != null && w > 0 && h > 0) ? w / h : 9.0 / 16.0;
                                    return Center(child: AspectRatio(aspectRatio: ar, child: cover));
                                  })
                                : const SizedBox(),
                            ),
                          );
                        }
                        return TweenAnimationBuilder<double>(
                          tween: Tween(begin: 1.0, end: 0.0),
                          duration: const Duration(milliseconds: 200),
                          builder: (context, opacity, child) {
                            if (opacity <= 0) return const SizedBox();
                            return Positioned.fill(
                              child: Opacity(
                                opacity: opacity,
                                child: child,
                              ),
                            );
                          },
                          child: (currentItem?.cover != null && _c.currentIndex.value > 0)
                            ? Obx(() {
                                final w = _c.videoWidth.value;
                                final h = _c.videoHeight.value;
                                _c.currentIndex.value;
                                final cover = Image.network(
                                  currentItem!.cover!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (a, b, c) => const SizedBox(),
                                );
                                final ar = (w != null && h != null && w > 0 && h > 0) ? w / h : 9.0 / 16.0;
                                return Container(
                                  color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                                  child: Center(child: AspectRatio(aspectRatio: ar, child: cover)),
                                );
                              })
                            : const SizedBox(),
                        );
                      }),
                      // Tap to play/pause overlay (below buttons on top, above video)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onTap: () {
                            _c.ensureStarted();
                            _c.togglePlay();
                          },
                        ),
                      ),
                      // Long-press right 1/6 area for 2x speed
                      Align(
                        alignment: Alignment.centerRight,
                        child: GestureDetector(
                          behavior: HitTestBehavior.translucent,
                          onLongPressStart: (_) => _c.setRate(2.0),
                          onLongPressEnd: (_) => _c.setRate(1.0),
                          child: Container(width: MediaQuery.sizeOf(context).width / 6),
                        ),
                      ),
                      if (currentItem != null)
                        Positioned(
                          left: 16,
                          right: 80,
                          bottom: 40,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (currentItem.owner?.name?.isNotEmpty == true)
                                Text(
                                  '@${currentItem.owner!.name}',
                                  style: TextStyle(
                                    color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              const SizedBox(height: 6),
                              Text(
                                currentItem.title ?? '',
                                style: TextStyle(color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black.withOpacity(0.8), fontSize: 13),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                      ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final barWidth = constraints.maxWidth;
                            return Obx(() {
                              final dur = _c.duration.value;
                              final pos = _c.position.value;
                              final fraction = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                              return MouseRegion(
                                cursor: SystemMouseCursors.click,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTapDown: (details) {
                                    _c.seekTo((details.localPosition.dx / barWidth).clamp(0.0, 1.0));
                                  },
                                  onHorizontalDragUpdate: (details) {
                                    _c.seekTo((details.localPosition.dx / barWidth).clamp(0.0, 1.0));
                                  },
                                  child: Container(
                                    height: 24,
                                    color: Colors.transparent,
                                    child: CustomPaint(
                                      painter: _ProgressBarPainter(
                                        fraction: fraction,
                                        blockSegments: _c.blockSegments,
                                          isDark: MediaQuery.platformBrightnessOf(context) == Brightness.dark,
                                        duration: dur.toInt(),
                                      ),
                                    ),
                                  ),
                                ),
                              );
                            });
                          },
                        ),
                      ),
                      Positioned(
                        right: 12,
                        bottom: 60,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _SideButton(
                              icon: Icons.arrow_upward,
                              label: '上一条',
                              onTap: () {
                                if (_c.currentIndex.value > 0) {
                                  _pageController.previousPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  );
                                }
                              },
                            ),
                            const SizedBox(height: 16),
                            _SideButton(
                              icon: Icons.arrow_downward,
                              label: '下一条',
                              onTap: () {
                                if (_c.currentIndex.value < _c.items.length - 1) {
                                  _pageController.nextPage(
                                    duration: const Duration(milliseconds: 300),
                                    curve: Curves.easeOut,
                                  );
                                }
                              },
                            ),
                            const SizedBox(height: 20),
                            _SideButton(
                              icon: Icons.copy,
                              label: '拷贝',
                              onTap: _copyCurrentVideo,
                            ),
                            const SizedBox(height: 20),
                            _SideButton(
                              icon: Icons.info_outline,
                              label: '详情页',
                              onTap: _c.openComment,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  );
                }),
              )
            : GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  _c.ensureStarted();
                  _c.togglePlay();
                },
                onVerticalDragStart: (_) {
                  _dragStartPixels = _pageController.position.pixels;
                },
                onVerticalDragUpdate: (details) {
                  if (_isAnimating) return;
                  final RenderBox? renderBox =
                      context.findRenderObject() as RenderBox?;
                  if (renderBox == null) return;
                  final double pageHeight = renderBox.size.height;
                  if (pageHeight <= 0) return;
                  final double newPixels =
                      (_dragStartPixels ?? _pageController.position.pixels) -
                          details.delta.dy;
                  final double maxPixels =
                      (_c.items.length - 1) * pageHeight;
                  final double clamped = newPixels.clamp(0.0, maxPixels);
                  _pageController.jumpTo(clamped);
                },
                onVerticalDragEnd: (details) {
                  if (_isAnimating) return;
                  final RenderBox? renderBox =
                      context.findRenderObject() as RenderBox?;
                  if (renderBox == null) return;
                  final double pageHeight = renderBox.size.height;
                  if (pageHeight <= 0) return;
                  final double currentPixels = _pageController.position.pixels;
                  final double targetPage =
                      (currentPixels / pageHeight).roundToDouble();
                  final int target =
                      targetPage.toInt().clamp(0, _c.items.length - 1);
                  _dragStartPixels = null;
                  _goToPage(target);
                },
                child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent || event is KeyRepeatEvent) {
                if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                  _c.ensureStarted();
                  _jumpToPage(_currentIndex + 1);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                  _c.ensureStarted();
                  _jumpToPage(_currentIndex - 1);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                  _c.ensureStarted();
                  _c.seekRelative(-5);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
                  _c.ensureStarted();
                  _c.seekRelative(5);
                  return KeyEventResult.handled;
                }
                if (event.logicalKey == LogicalKeyboardKey.space) {
                  _c.ensureStarted();
                  _c.togglePlay();
                  return KeyEventResult.handled;
                }
              }
              return KeyEventResult.ignored;
            },
            child: Obx(() {
              if (_c.isLoading.value && _c.items.isEmpty) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                );
              }
              if (_c.items.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('暂无短视频', style: TextStyle(color: Colors.white)),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: _c.loadFirst,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                );
              }

              // Current item for info overlay
              final currentItem = _c.items.isNotEmpty &&
                      _c.currentIndex.value >= 0 &&
                      _c.currentIndex.value < _c.items.length
                  ? _c.items[_c.currentIndex.value]
                  : null;

              return Stack(
                children: [
                  // 1. PageView for page switching (renders black pages)
                  PageView.builder(
                    controller: _pageController,
                    scrollDirection: Axis.vertical,
                    itemCount: _c.items.length,
                    physics: PlatformUtils.isMobile
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    onPageChanged: _onPageChanged,
                    itemBuilder: (context, index) =>
                        ColoredBox(color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF)),
                  ),

                  // 2. Video layer — centered with aspect ratio
                  // so letterbox areas show theme-colored background
                  if (_c.hasController.value)
                    Positioned.fill(
                      child: Obx(() {
                        final w = _c.videoWidth.value;
                        final h = _c.videoHeight.value;
                        _c.currentIndex.value; // rebuild on slot change
                        final ar = (w != null && h != null && w > 0 && h > 0) ? w / h : 9.0 / 16.0;
                        // Wider videos (1:1 to 16:9) shift up so bottom buttons are visible
                        final align = Alignment.center;
                        return Container(
                          color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                          child: Align(
                            alignment: align,
                            child: IgnorePointer(
                              child: Video(
                                controller: _c.videoController!,
                                fit: BoxFit.contain,
                                fill: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                                controls: null,
                                wakelock: false,
                              ),
                            ),
                          ),
                        );
                      }),
                    ),

                  // Cover image overlay - hide mpv gray flash (skip first video, unknown ratio)
                  if (currentItem?.cover != null && _c.currentIndex.value > 0)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: Obx(() {
                          final ready = _c.isVideoReady.value;
                          return TweenAnimationBuilder<double>(
                            tween: Tween(begin: 1.0, end: ready ? 0.0 : 1.0),
                            duration: const Duration(milliseconds: 800),
                            curve: Interval(0.75, 1.0, curve: Curves.easeOut),
                            builder: (context, opacity, child) {
                              if (opacity <= 0) return const SizedBox();
                              return Opacity(opacity: opacity, child: child);
                            },
                            child: Container(
                              color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black : const Color(0xFFFDFBFF),
                              child: Center(
                                child: Obx(() {
                                  final w = _c.videoWidth.value;
                                  final h = _c.videoHeight.value;
                                  final cover = Image.network(
                                    currentItem!.cover!,
                                    fit: BoxFit.contain,
                                    errorBuilder: (a, b, c) => const SizedBox(),
                                  );
                                  final ar = (w != null && h != null && w > 0 && h > 0) ? w / h : 9.0 / 16.0;
                                  return AspectRatio(
                                    aspectRatio: ar,
                                    child: cover,
                                  );
                                }),
                              ),
                            ),
                          );
                        }),
                      ),
                    ),

                  // 3. Info overlay at bottom
                  if (currentItem != null)
                    Positioned(
                      left: 16,
                      right: 80,
                      bottom: 40,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (currentItem.owner?.name?.isNotEmpty == true)
                            Text(
                              '@${currentItem.owner!.name}',
                              style: TextStyle(
                                color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            currentItem.title ?? '',
                            style: TextStyle(color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black.withOpacity(0.8), fontSize: 13),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),

                  // 4. Progress bar at bottom
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final barWidth = constraints.maxWidth;
                        return Obx(() {
                          final dur = _c.duration.value;
                          final pos = _c.position.value;
                          final fraction = dur > 0 ? (pos / dur).clamp(0.0, 1.0) : 0.0;
                          return MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) {
                                _c.seekTo((details.localPosition.dx / barWidth).clamp(0.0, 1.0));
                              },
                              onHorizontalDragUpdate: (details) {
                                _c.seekTo((details.localPosition.dx / barWidth).clamp(0.0, 1.0));
                              },
                              child: Container(
                                height: 24,
                                color: Colors.transparent,
                                child: Stack(
                                  children: [
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        height: 3,
                                        width: barWidth,
                                        color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white.withOpacity(0.2) : Colors.black.withOpacity(0.15),
                                      ),
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: Container(
                                        height: 3,
                                        width: barWidth * fraction,
                                        color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black.withOpacity(0.8),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        });
                      },
                    ),
                  ),

                  // 5. Right side buttons
                  Positioned(
                    right: 12,
                    bottom: 60,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SideButton(
                          icon: Icons.arrow_upward,
                          label: '上一条',
                          onTap: () {
                            if (_c.currentIndex.value > 0) {
                              _pageController.previousPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            }
                          },
                        ),
                        const SizedBox(height: 16),
                        _SideButton(
                          icon: Icons.arrow_downward,
                          label: '下一条',
                          onTap: () {
                            if (_c.currentIndex.value < _c.items.length - 1) {
                              _pageController.nextPage(
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOut,
                              );
                            }
                          },
                        ),
                        const SizedBox(height: 20),
                        _SideButton(
                          icon: Icons.copy,
                          label: '拷贝',
                          onTap: _copyCurrentVideo,
                        ),
                        const SizedBox(height: 20),
                        _SideButton(
                          icon: Icons.info_outline,
                          label: '详情页',
                          onTap: _c.openComment,
                        ),
                      ],
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _SideButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.black.withOpacity(0.5) : Colors.white.withOpacity(0.5),
          shape: const CircleBorder(),
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(icon, color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black, size: 24),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(label,
            style: TextStyle(color: MediaQuery.platformBrightnessOf(context) == Brightness.dark ? Colors.white : Colors.black, fontSize: 11)),
      ],
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  final double fraction;
  final List<List<dynamic>> blockSegments;
  final int duration;
  final bool isDark;

  _ProgressBarPainter({
    required this.fraction,
    required this.blockSegments,
    required this.duration,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const barY = 10.0;
    const barH = 3.0;

    // Background track
    canvas.drawRect(
      Rect.fromLTWH(0, barY, size.width, barH),
      Paint()..color = isDark ? Colors.white24 : Colors.black26,
    );

    // Block segments with category-specific colors
    if (duration > 0) {
      for (final seg in blockSegments) {
        final startFrac = (seg[0] / duration).clamp(0.0, 1.0);
        final endFrac = (seg[1] / duration).clamp(0.0, 1.0);
        final colorVal = seg[2] as int;
        canvas.drawRect(
          Rect.fromLTWH(size.width * startFrac, barY, size.width * (endFrac - startFrac), barH),
          Paint()..color = Color(colorVal).withOpacity(0.8),
        );
      }
    }

    // Played portion
    canvas.drawRect(
      Rect.fromLTWH(0, barY, size.width * fraction, barH),
      Paint()..color = isDark ? Colors.white.withOpacity(0.8) : Colors.black87,
    );
  }

  @override
  bool shouldRepaint(covariant _ProgressBarPainter oldDelegate) {
    return oldDelegate.fraction != fraction ||
        oldDelegate.blockSegments != blockSegments ||
        oldDelegate.duration != duration;
  }
}
