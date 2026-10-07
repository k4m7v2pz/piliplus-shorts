import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/video/video_type.dart';
import 'package:PiliPlus/pages/common/reply_controller.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:get/get.dart';

class VideoReplyController extends ReplyController<MainListReply>
    with ReplyVoteMixin {
  VideoReplyController({
    required this.aid,
    required this.videoType,
    required this.heroTag,
  });
  int aid;
  final VideoType videoType;
  late final isPugv = videoType == VideoType.pugv;

  final String heroTag;
  late final videoCtr = Get.find<VideoDetailController>(tag: heroTag);

  @override
  dynamic get sourceId => IdUtils.av2bv(aid);

  @override
  List<ReplyInfo>? getDataList(MainListReply response) {
    return response.replies;
  }

  @override
  void handleListResponse(List<ReplyInfo> dataList, {bool isRefresh = false}) {
    if (isRefresh) {
      // 刷新：整页替换旧列表，只去掉本页内的重复（B站热度排序偶尔同页重复）。
      final ids = <Int64>{};
      dataList.removeWhere((e) => !ids.add(e.id));
      return;
    }
    // 加载更多：与已显示列表去重，丢弃翻页边界重复的评论。
    // 注意：只影响显示，不影响游标翻页、回复/点赞/点踩等交互。
    if (loadingState.value case Success(:final response)) {
      final existing =
          (response ?? const <ReplyInfo>[]).map((e) => e.id).toSet();
      if (existing.isNotEmpty) {
        dataList.removeWhere((e) => existing.contains(e.id));
      }
    }
  }

  @override
  Future<LoadingState<MainListReply>> customGetData() async {
    var res = await _request();
    debugPrint('SVREPLY-DEBUG: first=${res.runtimeType} '
        'err=${res is Error ? res.errMsg : ''}');
    // B 站 gRPC 评论接口存在软风控：随机返回"成功但空列表"或
    // "非0状态但无错误详情（Error('')）"，两者都表现为"没有评论"。
    // 只要是无内容结果就重置游标自动重试（最多 2 次、间隔递增），
    // 全程停留在加载态，用户无感。
    if (_isEmptyResult(res)) {
      for (var attempt = 1; attempt <= 2; attempt++) {
        cursorNext = null;
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        res = await _request();
        debugPrint('SVREPLY-DEBUG: retry$attempt=${res.runtimeType} '
            'err=${res is Error ? res.errMsg : ''}');
        if (!_isEmptyResult(res)) break;
      }
    }
    return res;
  }

  bool _isEmptyResult(LoadingState<MainListReply> res) {
    if (res is Success<MainListReply>) return res.response.replies.isEmpty;
    if (res is Error) return (res.errMsg ?? '').trim().isEmpty;
    return false;
  }

  Future<LoadingState<MainListReply>> _request() => ReplyGrpc.mainList(
        oid: isPugv ? videoCtr.epId! : aid,
        type: videoType.replyType,
        mode: mode,
        cursorNext: cursorNext,
        offset: paginationReply?.nextOffset,
      );
}
