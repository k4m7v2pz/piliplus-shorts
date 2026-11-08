import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show MainListReply, ReplyInfo;
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/dynamic/dyn_mention/item.dart';
import 'package:PiliPlus/pages/common/reply/fold/reply_fold_mixin.dart';
import 'package:PiliPlus/pages/common/reply/reply_controller.dart';
import 'package:PiliPlus/pages/common/reply/vote/reply_vote_mixin.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply_reply/view.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:PiliPlus/utils/reply_scheme_helper.dart';
import 'package:fixnum/fixnum.dart' show Int64;
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/widgets.dart' show BoxConstraints, WidgetsBinding;
import 'package:get/get.dart';

class VideoReplyController extends ReplyController<MainListReply>
    with
        ReplyVoteMixin,
        GetSingleTickerProviderStateMixin,
        ReplyLocateMixin,
        MainReplyLocateMixin,
        BaseReplyFoldMixin<MainListReply>,
        ReplyFoldMixin {
  VideoReplyController({
    required this.heroTag,
  });
  late final isPugv = videoCtr.videoType == .pugv;

  @override
  int get oid => isPugv ? videoCtr.epId! : videoCtr.aid;

  @override
  int get replyType => videoCtr.videoType.replyType;

  final String heroTag;
  late final videoCtr = Get.find<VideoDetailController>(tag: heroTag);

  MentionItem? get mentionItem {
    if (videoCtr.isUgc) {
      try {
        return videoCtr.ugcIntroCtr.videoDetail.value.owner?.mentionItem;
      } catch (_) {
        if (kDebugMode) rethrow;
      }
    }
    return null;
  }

  @override
  dynamic get sourceId => IdUtils.av2bv(videoCtr.aid);

  @override
  void onAnimRootReply(ReplyInfo rootReply) {
    if (args[secondRpIdKey] case final int secondRpId) {
      clearTargetRootRpId();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => replyReply(rootReply, secondRpId),
      );
    } else {
      super.onAnimRootReply(rootReply);
    }
  }

  void replyReply(ReplyInfo replyItem, int? id) {
    videoCtr.childKey.currentState?.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => VideoReplyReplyPanel(
        id: id,
        oid: replyItem.oid.toInt(),
        rpid: replyItem.id.toInt(),
        firstFloor: replyItem.replyControl.isNote ? null : replyItem,
        replyType: videoCtr.videoType.replyType,
        isVideoDetail: true,
        isNested: videoCtr.scrollKey.currentContext != null,
        upMid: upMid,
      ),
    );
  }

  /// 本次响应是否来自下拉刷新。
  ///
  /// 上游 2.2.0 把评论区"去重"整体移除了（假空列表的根因也随之消失），
  /// 但加载更多时翻页边界仍会重复返回上一页的评论，所以只对加载更多去重；
  /// 刷新时绝不能与旧列表比对——旧做法就是把整页新评论误删，出现"假空列表"。
  bool _isRefreshResponse = false;

  @override
  bool customHandleResponse(bool isRefresh, Success<MainListReply> response) {
    _isRefreshResponse = isRefresh;
    return super.customHandleResponse(isRefresh, response);
  }

  @override
  void handleListResponse(List<ReplyInfo> dataList) {
    if (_isRefreshResponse) {
      // 刷新：整页替换，只去掉本页内的重复（B站热度排序偶尔同页重复）。
      final ids = <Int64>{};
      dataList.removeWhere((e) => !ids.add(e.id));
      return;
    }
    // 加载更多：与已显示列表去重。只影响显示，不影响游标翻页与回复/点赞。
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
    // 只要是无内容结果就原游标重试（最多 2 次、间隔递增），全程停在加载态，
    // 用户无感。注意别重置 offset：加载更多时重置会退回第一页。
    if (_isEmptyResult(res)) {
      for (var attempt = 1; attempt <= 2; attempt++) {
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
    oid: oid,
    rpid: rootRpId,
    type: replyType,
    mode: mode,
    offset: nextOffset,
  );
}
