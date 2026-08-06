import 'package:flutter/material.dart';

import '../../models/spotify_models.dart';
import '../../state/player_controller.dart';
import '../../theme/tokens.dart';
import 'atoms.dart';
import 'marquee_text.dart';

/// 「Up next」。`GET /me/player/queue` の返り値をそのまま並べるだけ（設計メモ §4）。
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key, required this.controller, required this.compact});

  final PlayerController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final next = controller.nextTrack;
    final rest = controller.restOfQueue;
    final accent = controller.palette.accent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (next != null)
          _NextUpCard(track: next, accent: accent, compact: compact)
        else
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 18,
              vertical: compact ? 20 : 26,
            ),
            decoration: BoxDecoration(
              borderRadius: AppRadius.card,
              border: Border.all(color: AppColors.white(0.16)),
            ),
            child: Text(
              compact
                  ? 'この先のキューは空です。'
                  : 'この先のキューは空です。\n曲を足すと続きます。',
              style: AppText.body(
                compact ? 14 : 15,
                color: AppColors.white(0.5),
                height: 1.7,
              ),
            ),
          ),
        SizedBox(height: compact ? 14 : 18),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: CapsLabel(
            '${controller.upNext.length} tracks ahead',
            size: compact ? 10 : 11,
            color: AppColors.white(0.35),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: EdgeInsets.zero,
            itemCount: rest.length + 1,
            itemBuilder: (context, index) {
              if (index == rest.length) {
                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 2),
                  child: Text(
                    'Spotify が返す先読みはおおむね 20 曲までです。',
                    style: AppText.body(
                      12,
                      color: AppColors.white(0.28),
                      height: 1.6,
                    ),
                  ),
                );
              }
              return _QueueRow(
                index: index + 2,
                track: rest[index],
                compact: compact,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NextUpCard extends StatelessWidget {
  const _NextUpCard({
    required this.track,
    required this.accent,
    required this.compact,
  });

  final Track track;
  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 14 : 16),
      decoration: BoxDecoration(
        borderRadius: AppRadius.card,
        color: AppColors.white(0.07),
        border: Border.all(color: AppColors.white(0.1)),
      ),
      child: Row(
        children: [
          Artwork(
            url: track.smallArtworkUrl ?? track.artworkUrl,
            size: compact ? 72 : 96,
            radius: AppRadius.thumb,
          ),
          SizedBox(width: compact ? 14 : 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                CapsLabel('Next up', size: compact ? 10 : 11, color: accent),
                SizedBox(height: compact ? 4 : 6),
                Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 19 : 24,
                    weight: FontWeight.w900,
                    height: 1.15,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  track.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 13 : 15,
                    color: AppColors.white(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.index,
    required this.track,
    required this.compact,
  });

  final int index;
  final Track track;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return HoverRow(
      padding: EdgeInsets.symmetric(horizontal: compact ? 4 : 8, vertical: 9),
      radius: const BorderRadius.all(Radius.circular(10)),
      child: Row(
        children: [
          SizedBox(
            width: compact ? 18 : 22,
            child: Text(
              '$index',
              textAlign: TextAlign.right,
              style: AppText.grotesk(
                size: compact ? 12 : 13,
                color: AppColors.white(0.3),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Artwork(
            url: track.smallArtworkUrl,
            size: compact ? 40 : 38,
            radius: AppRadius.thumbSmall,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(15, weight: FontWeight.w700),
                ),
                Text(
                  track.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(12, color: AppColors.white(0.45)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatDuration(Duration(milliseconds: track.durationMs)),
            style: AppText.grotesk(size: 12, color: AppColors.white(0.3)),
          ),
        ],
      ),
    );
  }
}

/// 「Add tracks」。`GET /search`（limit 10 固定・offset でページング）。
class SearchPanel extends StatefulWidget {
  const SearchPanel({
    super.key,
    required this.controller,
    required this.compact,
    required this.onPlayNow,
  });

  final PlayerController controller;
  final bool compact;
  final ValueChanged<Track> onPlayNow;

  @override
  State<SearchPanel> createState() => _SearchPanelState();
}

class _SearchPanelState extends State<SearchPanel> {
  late final TextEditingController _field = TextEditingController(
    text: widget.controller.query,
  );
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.removeListener(_maybeLoadMore);
    _scroll.dispose();
    _field.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 90) {
      widget.controller.loadMoreResults();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final compact = widget.compact;
    final results = controller.results;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _field,
          onChanged: controller.onQueryChanged,
          textInputAction: TextInputAction.search,
          style: AppText.body(
            compact ? 16 : 17,
            weight: FontWeight.w700,
            color: Colors.white,
          ),
          decoration: InputDecoration(
            hintText: '曲名・アーティストで検索',
            hintStyle: AppText.body(
              compact ? 16 : 17,
              weight: FontWeight.w700,
              color: AppColors.white(0.35),
            ),
            filled: true,
            fillColor: AppColors.white(0.07),
            contentPadding: EdgeInsets.symmetric(
              horizontal: compact ? 16 : 18,
              vertical: compact ? 14 : 16,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide(color: AppColors.white(0.14)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: AppColors.green),
            ),
            suffixIcon: controller.searchBusy
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.green,
                      ),
                    ),
                  )
                : null,
          ),
        ),
        SizedBox(height: compact ? 12 : 14),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.zero,
            itemCount: results.length + 1,
            itemBuilder: (context, index) {
              if (index == results.length) {
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 14,
                  ),
                  child: Text(
                    _footerLabel(controller),
                    textAlign: TextAlign.center,
                    style: AppText.body(
                      compact ? 12 : 13,
                      color: AppColors.white(0.32),
                    ),
                  ),
                );
              }
              return _SearchRow(
                track: results[index],
                compact: compact,
                onAdd: () => controller.addToQueue(results[index]),
                onPlayNow: () => widget.onPlayNow(results[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  String _footerLabel(PlayerController controller) {
    if (controller.query.trim().isEmpty) return '検索すると候補が出ます';
    if (controller.searchBusy) return '検索中…';
    if (controller.results.isEmpty) return '一致する曲がありません';
    return controller.searchHasMore ? 'スクロールでさらに 10 件' : 'これ以上ありません';
  }
}

class _SearchRow extends StatelessWidget {
  const _SearchRow({
    required this.track,
    required this.compact,
    required this.onAdd,
    required this.onPlayNow,
  });

  final Track track;
  final bool compact;
  final VoidCallback onAdd;
  final VoidCallback onPlayNow;

  @override
  Widget build(BuildContext context) {
    return HoverRow(
      padding: EdgeInsets.symmetric(horizontal: compact ? 2 : 8, vertical: 6),
      child: Row(
        children: [
          Artwork(
            url: track.smallArtworkUrl,
            size: compact ? 46 : 48,
            radius: const BorderRadius.all(Radius.circular(5)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  track.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 15 : 16,
                    weight: FontWeight.w700,
                  ),
                ),
                Text(
                  track.artists,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(12, color: AppColors.white(0.45)),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlineButton(
            label: 'Play now',
            onPressed: onPlayNow,
            fontSize: compact ? 12 : 13,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 11 : 12,
              vertical: 9,
            ),
          ),
          const SizedBox(width: 8),
          GreenButton(
            label: compact ? 'Add' : 'Add to queue',
            onPressed: onAdd,
            fontSize: compact ? 13 : 14,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 14 : 16,
              vertical: 10,
            ),
          ),
        ],
      ),
    );
  }
}

/// 「Playlists」。base として流すプレイリストを選ぶ。
/// 自分のプレイリストのみ（`GET /me/playlists`）。
///
/// [PlayerController.addingTrack] が入っているときだけ「追加先を選ぶ」モードに
/// なり、行の意味が **再生 → このリストへ追加** に変わる。意味が黙って変わると
/// 事故になるので、上の帯で対象の曲名を必ず出し、行のボタンも Play / Add で
/// 描き分ける。追加できないリスト（他人のもの）はこのモードでは並べない。
class PlaylistsPanel extends StatelessWidget {
  const PlaylistsPanel({
    super.key,
    required this.controller,
    required this.compact,
    required this.onPlay,
  });

  final PlayerController controller;
  final bool compact;
  final ValueChanged<PlaylistSummary> onPlay;

  @override
  Widget build(BuildContext context) {
    final accent = controller.palette.accent;
    final adding = controller.addingTrack;
    final playlists = adding == null
        ? controller.playlists
        : controller.editablePlaylists;

    // 追加しようとしている曲が、今流しているリストの曲そのものなら、
    // そのリストへの再追加は重複になる。行を潰して押させない。
    final alreadyInUri = adding != null && adding.uri == controller.currentTrack?.uri
        ? controller.currentTrackPlaylist?.uri
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (adding == null)
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MarqueeText(
                  controller.contextLabel,
                  style: AppText.body(
                    compact ? 11 : 12,
                    color: AppColors.white(0.42),
                    height: 1.6,
                  ),
                ),
              ),
            ],
          )
        else
          _AddingHeader(
            track: adding,
            accent: accent,
            compact: compact,
            onCancel: controller.cancelAddToPlaylist,
          ),
        SizedBox(height: compact ? 12 : 14),
        Expanded(
          child: !controller.playlistsLoaded
              ? const Center(
                  child: SizedBox.square(
                    dimension: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.green,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: EdgeInsets.zero,
                  itemCount: playlists.length + 1,
                  itemBuilder: (context, index) {
                    if (index == playlists.length) {
                      return Padding(
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 2),
                        child: Text(
                          _footnote(
                            adding: adding != null,
                            isEmpty: playlists.isEmpty,
                            hiddenCount: adding == null
                                ? 0
                                : controller.readOnlyPlaylistCount,
                          ),
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.28),
                            height: 1.6,
                          ),
                        ),
                      );
                    }
                    final playlist = playlists[index];
                    final mode = adding == null
                        ? _RowMode.play
                        : playlist.uri == alreadyInUri
                        ? _RowMode.alreadyIn
                        : _RowMode.add;
                    return _PlaylistRow(
                      playlist: playlist,
                      isContext: controller.isContext(playlist),
                      accent: accent,
                      compact: compact,
                      mode: mode,
                      onTap: switch (mode) {
                        _RowMode.play => () => onPlay(playlist),
                        _RowMode.add => () =>
                          controller.addToPlaylist(playlist, adding!),
                        _RowMode.alreadyIn => null,
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// 「追加先を選ぶ」モードの帯。対象の曲を出して、× で通常モードへ戻す。
class _AddingHeader extends StatelessWidget {
  const _AddingHeader({
    required this.track,
    required this.accent,
    required this.compact,
    required this.onCancel,
  });

  final Track track;
  final Color accent;
  final bool compact;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.playlist_add_rounded, size: compact ? 16 : 18, color: accent),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              CapsLabel('Add to playlist', size: 10, color: accent),
              const SizedBox(height: 3),
              Text(
                track.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(compact ? 13 : 14, weight: FontWeight.w900),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox.square(
          dimension: kMinTapTarget,
          child: IconButton(
            onPressed: onCancel,
            tooltip: '追加をやめる',
            padding: EdgeInsets.zero,
            icon: Icon(Icons.close_rounded, size: 20, color: AppColors.white(0.5)),
          ),
        ),
      ],
    );
  }
}

/// リストの行を押したときに何が起きるか。
enum _RowMode {
  /// base として流す（通常モード）。
  play,

  /// 選んだ曲をこのリストへ足す。
  add,

  /// もう入っている（＝今流しているリスト）。押させない。
  alreadyIn,
}

String _footnote({
  required bool adding,
  required bool isEmpty,
  required int hiddenCount,
}) {
  if (!adding) {
    return isEmpty
        ? 'プレイリストがありません。キューだけでも始められます。'
        : '自分のプレイリストのみ。Play で base として流し始めます。';
  }
  if (isEmpty) return '曲を足せるプレイリストがありません。';
  final base = '選んだリストの末尾に足します。再生中の曲やキューは変わりません。';
  // 落としたぶんを黙って隠すと「リストが足りない」ように見える。
  return hiddenCount == 0 ? base : '$base 編集できない $hiddenCount 件は除いています。';
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.isContext,
    required this.accent,
    required this.compact,
    required this.mode,
    required this.onTap,
  });

  final PlaylistSummary playlist;
  final bool isContext;
  final Color accent;
  final bool compact;
  final _RowMode mode;

  /// null なら押せない行（[_RowMode.alreadyIn]）。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 追加モードは iPad でも行全体で押せるようにする。右端のボタンだけが
    // 押せる状態だと、狙う先が Play のときと変わって間違えやすい。
    final rowTap = compact || mode != _RowMode.play ? onTap : null;
    return Opacity(
      opacity: mode == _RowMode.alreadyIn ? 0.45 : 1,
      child: _rowBody(rowTap),
    );
  }

  Widget _rowBody(VoidCallback? rowTap) {
    return HoverRow(
      // スマホは行全体タップ、iPad は右端の Play ボタン。
      onTap: rowTap,
      padding: EdgeInsets.all(compact ? 8 : 10),
      radius: const BorderRadius.all(Radius.circular(14)),
      child: Row(
        children: [
          Artwork(
            url: playlist.artworkUrl,
            size: compact ? 52 : 62,
            radius: compact
                ? const BorderRadius.all(Radius.circular(5))
                : AppRadius.thumb,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 15 : 17,
                    weight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  playlist.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 11 : 12,
                    color: AppColors.white(0.45),
                  ),
                ),
                if (isContext && !compact) ...[
                  const SizedBox(height: 3),
                  CapsLabel('Playing', size: 11, color: accent),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (compact) ...[
            if (mode == _RowMode.alreadyIn)
              CapsLabel('In list', size: 10, color: accent)
            else if (isContext)
              CapsLabel('Playing', size: 10, color: accent),
            const SizedBox(width: 8),
            Icon(
              mode == _RowMode.play
                  ? Icons.play_arrow_rounded
                  : Icons.playlist_add_rounded,
              color: AppColors.white(0.5),
              size: 22,
            ),
          ] else if (mode == _RowMode.alreadyIn)
            CapsLabel('In list', size: 11, color: accent)
          else if (mode == _RowMode.add)
            GreenButton(
              label: 'Add',
              onPressed: onTap,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            )
          else
            WhiteButton(
              label: 'Play',
              onPressed: onTap,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
        ],
      ),
    );
  }
}
