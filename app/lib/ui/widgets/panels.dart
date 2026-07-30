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
    final playlists = controller.playlists;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
        ),
        SizedBox(height: compact ? 10 : 12),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 16,
            vertical: compact ? 6 : 7,
          ),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.all(Radius.circular(14)),
            color: AppColors.white(0.05),
            border: Border.all(color: AppColors.white(0.09)),
          ),
          child: Row(
            children: [
              ShuffleSwitch(
                value: controller.shuffleOn,
                onChanged: controller.setShuffle,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  controller.shuffleOn ? 'Shuffle on' : 'Shuffle off',
                  style: AppText.body(
                    compact ? 14 : 15,
                    weight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
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
                          playlists.isEmpty
                              ? 'プレイリストがありません。キューだけでも始められます。'
                              : '自分のプレイリストのみ。Play で base として流し始めます。',
                          style: AppText.body(
                            12,
                            color: AppColors.white(0.28),
                            height: 1.6,
                          ),
                        ),
                      );
                    }
                    return _PlaylistRow(
                      playlist: playlists[index],
                      isContext: controller.isContext(playlists[index]),
                      accent: accent,
                      compact: compact,
                      onPlay: () => onPlay(playlists[index]),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _PlaylistRow extends StatelessWidget {
  const _PlaylistRow({
    required this.playlist,
    required this.isContext,
    required this.accent,
    required this.compact,
    required this.onPlay,
  });

  final PlaylistSummary playlist;
  final bool isContext;
  final Color accent;
  final bool compact;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return HoverRow(
      // スマホは行全体タップ、iPad は右端の Play ボタン。
      onTap: compact ? onPlay : null,
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
            if (isContext) CapsLabel('Playing', size: 10, color: accent),
            const SizedBox(width: 8),
            Icon(Icons.play_arrow_rounded, color: AppColors.white(0.5), size: 22),
          ] else
            WhiteButton(
              label: 'Play',
              onPressed: onPlay,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
        ],
      ),
    );
  }
}
