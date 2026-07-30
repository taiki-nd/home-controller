import 'dart:ui';

import 'package:flutter/material.dart';

import '../../models/spotify_models.dart';
import '../../theme/tokens.dart';
import 'atoms.dart';

/// 停止中（`GET /me/player` が 204）の告知。エラーではないのでアンバー。
/// 復帰ロジックは持たず、曲を足す導線だけ出す（設計メモ §5）。
class StoppedBanner extends StatelessWidget {
  const StoppedBanner({super.key, required this.onResume});

  final VoidCallback onResume;

  /// 帯そのものの高さ。画面の天から置くので、実際の見た目はこれに
  /// ステータスバーぶん（SafeArea）が足された高さになる。
  static const height = 72.0;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: AppColors.amber.withValues(alpha: 0.14),
            border: Border(
              bottom: BorderSide(color: AppColors.amber.withValues(alpha: 0.35)),
            ),
          ),
          // アンバーの面はステータスバーまで塗り、中身だけその下から始める。
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              child: Row(
                children: [
                  const StatusDot(
                    color: AppColors.amber,
                    size: 10,
                    pulse: false,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      '停止中 — キューを使い切りました',
                      style: AppText.body(
                        15,
                        weight: FontWeight.w700,
                        color: AppColors.amberText,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  _AmberButton(label: '曲を足して再開', onPressed: onResume),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AmberButton extends StatelessWidget {
  const _AmberButton({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.amber,
      borderRadius: AppRadius.pill,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          constraints: const BoxConstraints(minHeight: kMinTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: 18),
          alignment: Alignment.center,
          child: Text(
            label,
            style: AppText.body(
              14,
              weight: FontWeight.w900,
              color: AppColors.onAmber,
            ),
          ),
        ),
      ),
    );
  }
}

/// 404 NO_ACTIVE_DEVICE。設計メモ §9 の「公式アプリで一度起こす」導線。
class NoDeviceOverlay extends StatelessWidget {
  const NoDeviceOverlay({
    super.key,
    required this.onRescan,
    required this.onDismiss,
  });

  final VoidCallback onRescan;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return _Scrim(
      child: _DialogCard(
        maxWidth: 520,
        children: [
          const CapsLabel(
            'No active device · 404',
            size: 11,
            color: AppColors.danger,
          ),
          const SizedBox(height: 18),
          Text(
            'WiiM が見つかりません',
            style: AppText.body(
              30,
              weight: FontWeight.w900,
              height: 1.2,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 18),
          Text(
            'スリープ中の WiiM は Connect のデバイス一覧に出てこないことがあります。'
            '公式 Spotify アプリから一度再生して起こすと、以降はここから操作できます。',
            style: AppText.body(16, color: AppColors.white(0.65), height: 1.8),
          ),
          const SizedBox(height: 22),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              WhiteButton(label: 'もう一度探す', onPressed: onRescan),
              OutlineButton(label: 'あとで', onPressed: onDismiss),
            ],
          ),
        ],
      ),
    );
  }
}

/// 「今すぐ再生」の確認。キューと context が消えることを事前に伝える（設計メモ §5）。
class PlayNowConfirm extends StatelessWidget {
  const PlayNowConfirm({
    super.key,
    required this.track,
    required this.queueCount,
    required this.onConfirm,
    required this.onCancel,
  });

  final Track track;
  final int queueCount;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return _Scrim(
      onTapOutside: onCancel,
      child: _DialogCard(
        maxWidth: 460,
        children: [
          Text(
            '「${track.name}」を今すぐ再生',
            style: AppText.body(
              26,
              weight: FontWeight.w900,
              height: 1.25,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'この操作で、現在のキュー（$queueCount 曲）と base のプレイリストが '
            'Spotify 側で破棄されます。',
            style: AppText.body(15, color: AppColors.white(0.62), height: 1.8),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              GreenButton(label: 'キューを捨てて再生', onPressed: onConfirm),
              OutlineButton(label: 'キャンセル', onPressed: onCancel),
            ],
          ),
        ],
      ),
    );
  }
}

/// プレイリストを base に切り替える確認。ここでシャッフルも確定させる。
class PlaylistConfirm extends StatefulWidget {
  const PlaylistConfirm({
    super.key,
    required this.playlist,
    required this.queueCount,
    required this.initialShuffle,
    required this.onConfirm,
    required this.onCancel,
  });

  final PlaylistSummary playlist;
  final int queueCount;
  final bool initialShuffle;
  final void Function(bool shuffle) onConfirm;
  final VoidCallback onCancel;

  @override
  State<PlaylistConfirm> createState() => _PlaylistConfirmState();
}

class _PlaylistConfirmState extends State<PlaylistConfirm> {
  late bool _shuffle = widget.initialShuffle;

  @override
  Widget build(BuildContext context) {
    return _Scrim(
      onTapOutside: widget.onCancel,
      child: _DialogCard(
        maxWidth: 460,
        children: [
          CapsLabel('Set context', size: 11, color: AppColors.white(0.4)),
          const SizedBox(height: 14),
          Text(
            '「${widget.playlist.name}」から再生',
            style: AppText.body(
              26,
              weight: FontWeight.w900,
              height: 1.25,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'base を切り替えると、現在のキュー（${widget.queueCount} 曲）は破棄されます。',
            style: AppText.body(15, color: AppColors.white(0.62), height: 1.8),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(14)),
              color: AppColors.white(0.05),
              border: Border.all(color: AppColors.white(0.1)),
            ),
            child: Row(
              children: [
                ShuffleSwitch(
                  value: _shuffle,
                  onChanged: (value) => setState(() => _shuffle = value),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _shuffle ? 'Shuffle on' : 'Shuffle off',
                    style: AppText.body(15, weight: FontWeight.w900),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              WhiteButton(
                label: 'このリストを再生',
                onPressed: () => widget.onConfirm(_shuffle),
              ),
              OutlineButton(label: 'キャンセル', onPressed: widget.onCancel),
            ],
          ),
        ],
      ),
    );
  }
}

/// Connect デバイス一覧。
class DevicePopover extends StatelessWidget {
  const DevicePopover({
    super.key,
    required this.devices,
    required this.activeDeviceId,
    required this.onPick,
    required this.onRescan,
    this.width = 340,
  });

  final List<SpotifyDevice> devices;
  final String? activeDeviceId;
  final ValueChanged<SpotifyDevice> onPick;
  final VoidCallback onRescan;
  final double width;

  /// 箱の左端から行の点までの距離（枠線 1 + 外周 10 + 行の左パディング 12）。
  /// 呼ぶ側はここを引いて置くことで、点をピルの点の真下に落とせる。
  static const dotInset = 23.0;

  /// ピルの点の x に点を合わせるための左位置。
  static double leftForPillDotX(double pillDotX) => pillDotX - dotInset;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: Container(
        width: width,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: AppRadius.popover,
          color: AppColors.popover.withValues(alpha: 0.97),
          border: Border.all(color: AppColors.white(0.12)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.9),
              blurRadius: 70,
              spreadRadius: -20,
              offset: const Offset(0, 30),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
              child: CapsLabel('Devices', size: 11),
            ),
            if (devices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Text(
                  'デバイスが見つかりません',
                  style: AppText.body(14, color: AppColors.white(0.5)),
                ),
              )
            else
              for (final device in devices)
                _DeviceRow(
                  device: device,
                  selected: device.id != null && device.id == activeDeviceId,
                  onTap: () => onPick(device),
                ),
            const SizedBox(height: 4),
            OutlineButton(
              label: 'もう一度探す',
              onPressed: onRescan,
              fontSize: 14,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.selected,
    required this.onTap,
  });

  final SpotifyDevice device;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 出力できない先（restricted / id 無し）はグレーの点で示す。
    final usable = !device.isRestricted && device.id != null;
    return HoverRow(
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          StatusDot(
            color: selected && usable ? AppColors.green : AppColors.dotIdle,
            pulse: false,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: CapCentered(
              fontSize: 16,
              child: Text(
                device.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(16, weight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(width: 8),
          CapCentered(
            fontSize: 12,
            child: Text(
              device.kindLabel,
              style: AppText.body(12, color: AppColors.white(0.4)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 追加完了などの短いフィードバック。
class AppToast extends StatelessWidget {
  const AppToast({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(text),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 15),
        decoration: BoxDecoration(
          borderRadius: AppRadius.pill,
          color: Colors.white.withValues(alpha: 0.95),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.7),
              blurRadius: 44,
              spreadRadius: -14,
              offset: const Offset(0, 20),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const StatusDot(color: AppColors.green, size: 10, pulse: false),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                text,
                style: AppText.body(
                  16,
                  weight: FontWeight.w900,
                  color: AppColors.onWhite,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 書き込み系が失敗したときだけ出す薄い赤帯。ポーリング失敗では出さない。
class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    // ステータスバーぶんは呼ぶ側（controller_screen）が y に足して置くので、
    // ここで SafeArea を掛けると二重に下がる。
    return Material(
      color: AppColors.danger.withValues(alpha: 0.16),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 10, 8, 10),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: AppColors.danger, size: 18),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: AppText.body(
                  14,
                  weight: FontWeight.w700,
                  color: AppColors.white(0.9),
                ),
              ),
            ),
            IconButton(
              onPressed: onDismiss,
              icon: Icon(Icons.close, color: AppColors.white(0.7), size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.child, this.onTapOutside});

  final Widget child;
  final VoidCallback? onTapOutside;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onTapOutside,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: ColoredBox(
                color: const Color(0xFF060608).withValues(alpha: 0.8),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: child,
            ),
          ),
        ),
      ],
    );
  }
}

class _DialogCard extends StatelessWidget {
  const _DialogCard({required this.children, required this.maxWidth});

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: Container(
          padding: const EdgeInsets.all(30),
          decoration: BoxDecoration(
            borderRadius: AppRadius.dialog,
            color: AppColors.surface,
            border: Border.all(color: AppColors.white(0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.9),
                blurRadius: 90,
                spreadRadius: -30,
                offset: const Offset(0, 40),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }
}
