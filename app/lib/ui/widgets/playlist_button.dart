import 'package:flutter/material.dart';

import '../../models/spotify_models.dart';
import '../../state/player_controller.dart';
import '../../theme/tokens.dart';

/// 「この曲をこのリストから外したい」の投げ上げ。確認ダイアログは画面側が出す。
typedef PlaylistRemoveRequest =
    void Function(PlaylistSummary playlist, Track track);

/// 再生中の曲をプレイリストから外す / どこかに入れる、1 つのボタン。
///
/// 状態は [PlayerController.currentTrackPlaylist] だけで決まる。つまり
/// **「今流しているプレイリストに入っているか」しか見ていない。** 他のリストに
/// 入っているかどうかは Spotify の API では安く判定できないので（あちらのコメント
/// 参照）、ラベルに必ずリスト名を出して「そのリストから外す」と言い切る形にする。
/// 「＋」は「どこにも入っていない」ではなく「入れる先を選ぶ」の意味。
///
/// 削除は取り消しづらいので確認を挟む。ダイアログは他の確認と同じく画面側が
/// 持つので、[onRemove] で投げ上げる。追加は選択画面へ移るだけなので、ここから
/// コントローラを直接叩く。
class PlaylistToggleButton extends StatelessWidget {
  const PlaylistToggleButton({
    super.key,
    required this.controller,
    required this.compact,
    required this.onRemove,
  });

  final PlayerController controller;

  /// スマホは丸アイコン、iPad はリスト名入りのピル。
  final bool compact;

  final PlaylistRemoveRequest onRemove;

  @override
  Widget build(BuildContext context) {
    final track = controller.currentTrack;
    // 停止中は対象の曲が無い。場所だけ空けても意味が無いので消す。
    if (track == null) return const SizedBox.shrink();

    final playlist = controller.currentTrackPlaylist;
    final inPlaylist = playlist != null;
    final label = inPlaylist ? '${playlist.name} から削除' : 'プレイリストに追加';

    void onTap() {
      if (inPlaylist) {
        onRemove(playlist, track);
      } else {
        controller.beginAddToPlaylist(track);
      }
    }

    return Semantics(
      button: true,
      label: label,
      child: Tooltip(
        message: label,
        child: compact
            ? _Round(inPlaylist: inPlaylist, onTap: onTap)
            : _Labelled(
                inPlaylist: inPlaylist,
                text: inPlaylist ? playlist.name : 'Add to playlist',
                onTap: onTap,
              ),
      ),
    );
  }
}

/// 入っている＝緑の塗り、入っていない＝ガラス。デバイスピルと同じ面の作り。
IconData _iconFor({required bool inPlaylist}) =>
    inPlaylist ? Icons.playlist_add_check_rounded : Icons.playlist_add_rounded;

Color _fillFor({required bool inPlaylist}) =>
    inPlaylist ? AppColors.green : Colors.black.withValues(alpha: 0.35);

Color _inkFor({required bool inPlaylist}) =>
    inPlaylist ? AppColors.onGreen : AppColors.white(0.85);

BorderSide _sideFor({required bool inPlaylist}) =>
    inPlaylist ? BorderSide.none : BorderSide(color: AppColors.white(0.16));

class _Round extends StatelessWidget {
  const _Round({required this.inPlaylist, required this.onTap});

  final bool inPlaylist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: _fillFor(inPlaylist: inPlaylist),
      shape: CircleBorder(side: _sideFor(inPlaylist: inPlaylist)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          width: kMinTapTarget,
          height: kMinTapTarget,
          child: Icon(
            _iconFor(inPlaylist: inPlaylist),
            size: 22,
            color: _inkFor(inPlaylist: inPlaylist),
          ),
        ),
      ),
    );
  }
}

class _Labelled extends StatelessWidget {
  const _Labelled({
    required this.inPlaylist,
    required this.text,
    required this.onTap,
  });

  final bool inPlaylist;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ink = _inkFor(inPlaylist: inPlaylist);
    return Material(
      color: _fillFor(inPlaylist: inPlaylist),
      shape: RoundedRectangleBorder(
        borderRadius: AppRadius.pill,
        side: _sideFor(inPlaylist: inPlaylist),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_iconFor(inPlaylist: inPlaylist), size: 18, color: ink),
              const SizedBox(width: 8),
              // 長いリスト名でアートワークの列を押し出さないよう頭を止める。
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(14, weight: FontWeight.w700, color: ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
