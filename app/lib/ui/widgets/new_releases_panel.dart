import 'package:flutter/material.dart';

import '../../models/release_models.dart';
import '../../state/new_releases_controller.dart';
import '../../theme/tokens.dart';
import 'atoms.dart';

/// 「New」。フォロー中アーティストの新譜（設計メモ §14）。
///
/// **リリース情報とジャケットは MusicBrainz / Cover Art Archive 由来で、
/// Spotify のものではない。** 押されるまで Spotify には一切問い合わせない。
class NewReleasesPanel extends StatefulWidget {
  const NewReleasesPanel({
    super.key,
    required this.controller,
    required this.compact,
    required this.onPlay,
    this.now,
  });

  final NewReleasesController controller;
  final bool compact;

  /// 行を押したとき。Spotify のアルバムへの引き当てはここから先の担当。
  final ValueChanged<NewRelease> onPlay;

  final DateTime Function()? now;

  @override
  State<NewReleasesPanel> createState() => _NewReleasesPanelState();
}

class _NewReleasesPanelState extends State<NewReleasesPanel> {
  @override
  void initState() {
    super.initState();
    // タブを開いた時点で取りに行く。2 回目以降は ready なら何もしない。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final compact = widget.compact;
    final now = (widget.now ?? DateTime.now)();

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final upcoming = controller.upcoming;
        final released = controller.released;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(controller: controller, compact: compact),
            SizedBox(height: compact ? 12 : 14),
            Expanded(child: _body(controller, upcoming, released, now)),
          ],
        );
      },
    );
  }

  Widget _body(
    NewReleasesController controller,
    List<NewRelease> upcoming,
    List<NewRelease> released,
    DateTime now,
  ) {
    if (controller.isLoading && controller.releases.isEmpty) {
      return const Center(
        child: SizedBox.square(
          dimension: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.green,
          ),
        ),
      );
    }

    if (controller.status == NewReleasesStatus.failed) {
      return _Message(
        text: controller.error ?? '新譜を取得できませんでした',
        actionLabel: 'もう一度',
        onAction: () => controller.load(force: true),
      );
    }

    if (controller.releases.isEmpty) {
      final message = _Message(
        text: controller.coverage.followed == 0
            ? 'フォロー中のアーティストがいません。\nSpotify でアーティストをフォローすると、ここに新譜が並びます。'
            : 'この ${NewReleasesController.pastDays} 日間と、'
                  'この先 ${NewReleasesController.futureDays} 日間に'
                  '出るアルバムはありません。',
        actionLabel: '取り直す',
        onAction: () => controller.load(force: true),
      );
      // **1 件も出ないときこそ理由が要る。** 脚注はここにも出す
      // （照合から漏れた名前が並ぶ）。
      if (controller.coverage.missing == 0) return message;
      return ListView(
        padding: EdgeInsets.zero,
        children: [
          SizedBox(height: widget.compact ? 24 : 40),
          message,
          _Footnote(controller: controller),
        ],
      );
    }

    // 未発売と発売済みで見出しを分ける。順序は controller が決めている。
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        if (upcoming.isNotEmpty) ...[
          _SectionLabel('Coming soon', compact: widget.compact),
          for (final release in upcoming)
            _ReleaseRow(
              release: release,
              now: now,
              compact: widget.compact,
              onPlay: () => widget.onPlay(release),
            ),
          SizedBox(height: widget.compact ? 12 : 16),
        ],
        if (released.isNotEmpty) ...[
          _SectionLabel('Just out', compact: widget.compact),
          for (final release in released)
            _ReleaseRow(
              release: release,
              now: now,
              compact: widget.compact,
              onPlay: () => widget.onPlay(release),
            ),
        ],
        _Footnote(controller: controller),
      ],
    );
  }
}

/// カバー率と再取得。**取りこぼしを黙って捨てない**ための行（設計メモ §14）。
class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.compact});

  final NewReleasesController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final coverage = controller.coverage;
    return Row(
      children: [
        Expanded(
          child: Text(
            coverage.followed == 0
                ? 'フォロー中アーティストの新譜'
                : 'フォロー ${coverage.followed} 組中 ${coverage.resolved} 組を照合',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.body(
              compact ? 11 : 12,
              color: AppColors.white(0.42),
              height: 1.6,
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (controller.isLoading)
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.green,
            ),
          )
        else
          GestureDetector(
            onTap: () => controller.load(force: true),
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Icon(
                Icons.refresh_rounded,
                size: compact ? 16 : 18,
                color: AppColors.white(0.5),
              ),
            ),
          ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {required this.compact});

  final String text;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
      child: CapsLabel(
        text,
        size: compact ? 10 : 11,
        color: AppColors.white(0.35),
      ),
    );
  }
}

class _ReleaseRow extends StatelessWidget {
  const _ReleaseRow({
    required this.release,
    required this.now,
    required this.compact,
    required this.onPlay,
  });

  final NewRelease release;
  final DateTime now;
  final bool compact;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final upcoming = release.isUpcoming(now);
    return HoverRow(
      onTap: compact ? onPlay : null,
      padding: EdgeInsets.all(compact ? 8 : 10),
      radius: const BorderRadius.all(Radius.circular(14)),
      child: Row(
        children: [
          Artwork(
            url: release.coverArtUrl,
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
                  release.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 15 : 17,
                    weight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  release.artistName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    compact ? 11 : 12,
                    color: AppColors.white(0.45),
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    CapsLabel(
                      release.dateLabel(now),
                      size: compact ? 10 : 11,
                      // 未発売は「まだ鳴らせない」ので色で区別する。
                      color: upcoming ? AppColors.amber : AppColors.white(0.35),
                    ),
                    if (release.typeLabel != null) ...[
                      const SizedBox(width: 8),
                      // `Album · Remix` まで伸びるので、日付ラベルを押し出さない
                      // よう幅は余りぶんだけ。
                      Flexible(
                        child: Text(
                          release.typeLabel!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppText.body(
                            compact ? 10 : 11,
                            color: AppColors.white(0.28),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          if (compact)
            Icon(
              Icons.play_arrow_rounded,
              color: AppColors.white(upcoming ? 0.25 : 0.5),
              size: 22,
            )
          else
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

/// 出所の明示と、照合から漏れたアーティスト。
class _Footnote extends StatefulWidget {
  const _Footnote({required this.controller});

  final NewReleasesController controller;

  @override
  State<_Footnote> createState() => _FootnoteState();
}

class _FootnoteState extends State<_Footnote> {
  /// 畳まずに出す名前の数。
  ///
  /// **漏れた組数だけでは「誰が出ていないのか」が分からない**ので名前を出すが、
  /// フォローが多いと数十組になる。全部並べると新譜より脚注のほうが長くなって
  /// しまうので、はじめはここまでにして残りは畳む。
  static const _previewCount = 8;

  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final missing = widget.controller.coverage.missing;
    final names = widget.controller.unresolvedArtists;
    final hidden = names.length - _previewCount;
    final shown = _expanded || hidden <= 0
        ? names
        : names.take(_previewCount).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 18, 8, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'リリース情報は MusicBrainz、ジャケットは Cover Art Archive です。'
            'アルバムと EP のみを出しています。',
            style: AppText.body(12, color: AppColors.white(0.28), height: 1.6),
          ),
          if (missing > 0) ...[
            const SizedBox(height: 8),
            Text(
              'フォロー中 $missing 組は MusicBrainz 側に Spotify の対応付けが無いため、'
              'この一覧に出ません。',
              style: AppText.body(12, color: AppColors.white(0.28), height: 1.6),
            ),
            if (shown.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                shown.join('、'),
                // 本文より明るくする。ここは「読ませたい情報」で、
                // 上 2 行の但し書きとは役割が違う。
                style: AppText.body(
                  12,
                  color: AppColors.white(0.42),
                  height: 1.6,
                ),
              ),
            ],
            if (hidden > 0)
              GestureDetector(
                onTap: () => setState(() => _expanded = !_expanded),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    _expanded ? '畳む' : 'ほか $hidden 組を表示',
                    style: AppText.body(
                      12,
                      color: AppColors.green,
                      height: 1.6,
                    ),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.text,
    required this.actionLabel,
    required this.onAction,
  });

  final String text;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: AppText.body(
                14,
                color: AppColors.white(0.5),
                height: 1.7,
              ),
            ),
            const SizedBox(height: 16),
            OutlineButton(label: actionLabel, onPressed: onAction),
          ],
        ),
      ),
    );
  }
}
