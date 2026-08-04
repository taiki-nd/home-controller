import 'package:flutter/material.dart';

import '../../../models/ha_models.dart';
import '../../../theme/tokens.dart';
import '../../widgets/atoms.dart';

/// 家電のタイル。
///
/// **枠線を引かない。** 壁掛けの iPad に固定のグリッドを出しっぱなしにするので、
/// 幅 1px・輝度一定の線がいちばん焼きつく（`SoftSurface` のコメントと同じ理由）。
/// 面の塗りの差だけで区切る。
///
/// ON は色を変えるのではなく**面が光る**。照明が実際に光るというメタファーが
/// そのまま状態表示になるので凡例が要らず、Spotify グリーンとも衝突しない。
class HomeTile extends StatelessWidget {
  const HomeTile({
    super.key,
    required this.entity,
    required this.onTap,
    this.onLongPress,
    this.onNudge,
  });

  final HaEntity entity;
  final VoidCallback onTap;

  /// 調光など。無ければ長押ししても何も起きない。
  final VoidCallback? onLongPress;

  /// エアコンの温度±。`steps` は -1 / +1。
  final ValueChanged<int>? onNudge;

  static const height = 140.0;

  @override
  Widget build(BuildContext context) {
    final on = entity.isOn;
    final unavailable = entity.isUnavailable;

    // ON: 電球色を薄く重ねて面を持ち上げる。OFF: 既存の面のまま沈める。
    // 応答なしはさらに沈めて文字も落とす（色を足して「エラー色」にしない）。
    final background = unavailable
        ? AppColors.white(0.03)
        : on
        ? Color.alphaBlend(
            AppColors.homeGlow.withValues(alpha: 0.22),
            AppColors.white(0.06),
          )
        : AppColors.white(0.055);

    final foreground = unavailable
        ? AppColors.white(0.32)
        : on
        ? Colors.white
        : AppColors.white(0.72);

    return Semantics(
      button: true,
      toggled: entity.kind == HaTileKind.press ? null : on,
      label: entity.name,
      child: _TileSurface(
        background: background,
        onTap: unavailable ? null : onTap,
        onLongPress: unavailable ? null : onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(_iconFor(entity), size: 22, color: foreground),
                  const Spacer(),
                  if (entity.kind == HaTileKind.climate && !unavailable)
                    _TempStepper(entity: entity, onNudge: onNudge),
                ],
              ),
              const Spacer(),
              Text(
                entity.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppText.body(
                  16,
                  weight: FontWeight.w700,
                  color: foreground,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _subtitleFor(entity),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.grotesk(
                  size: 12,
                  weight: 600,
                  color: foreground.withValues(alpha: 0.62),
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// エアコンの温度±。タイルの中で完結させる（スライダは詳細シートに逃がす）。
class _TempStepper extends StatelessWidget {
  const _TempStepper({required this.entity, required this.onNudge});

  final HaEntity entity;
  final ValueChanged<int>? onNudge;

  @override
  Widget build(BuildContext context) {
    final target = entity.targetTemperature;
    if (target == null || !entity.isOn) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(icon: Icons.remove, onTap: () => onNudge?.call(-1)),
        SizedBox(
          width: 46,
          child: Text(
            _formatTemp(target),
            textAlign: TextAlign.center,
            style: AppText.grotesk(size: 17, weight: 700, color: Colors.white),
          ),
        ),
        _StepButton(icon: Icons.add, onTap: () => onNudge?.call(1)),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      // タイル本体のタップ（= ON/OFF）に吸われないよう、当たり判定を確保する。
      child: SizedBox.square(
        dimension: 34,
        child: Icon(icon, size: 18, color: Colors.white),
      ),
    );
  }
}

/// 面。線を引かず、角丸と塗りだけで箱にする。
class _TileSurface extends StatelessWidget {
  const _TileSurface({
    required this.background,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  final Color background;
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: background,
        borderRadius: AppRadius.card,
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, onLongPress: onLongPress, child: child),
      ),
    );
  }
}

/// 押せない数値。タイルの形にすると押せると誤解されるので、行に流す。
class SensorReadouts extends StatelessWidget {
  const SensorReadouts({super.key, required this.entities});

  final List<HaEntity> entities;

  @override
  Widget build(BuildContext context) {
    if (entities.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 22,
      runSpacing: 8,
      children: [
        for (final entity in entities)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CapsLabel(entity.name, size: 10),
              const SizedBox(width: 8),
              Text(
                entity.readout,
                style: AppText.grotesk(
                  size: 14,
                  weight: 700,
                  color: AppColors.white(0.78),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// 部屋の一覧。music 側が「左に主役・右にレール」なので、home は鏡像にする。
class RoomRail extends StatelessWidget {
  const RoomRail({
    super.key,
    required this.rooms,
    required this.selectedId,
    required this.onSelect,
    required this.hasOn,
  });

  final List<HaRoom> rooms;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  /// その部屋で何か点いているか。
  final bool Function(String roomId) hasOn;

  static const width = 280.0;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: rooms.length,
      itemBuilder: (context, index) {
        final room = rooms[index];
        final selected = room.id == selectedId;
        return HoverRow(
          onTap: () => onSelect(room.id),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  room.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.body(
                    17,
                    weight: selected ? FontWeight.w900 : FontWeight.w500,
                    color: selected ? Colors.white : AppColors.white(0.6),
                  ),
                ),
              ),
              if (hasOn(room.id))
                const StatusDot(color: AppColors.homeDot, size: 7, pulse: false),
            ],
          ),
        );
      },
    );
  }
}

String _formatTemp(double value) {
  // 24.0 は「24」、24.5 は「24.5」。壁掛けで読むので桁を増やさない。
  final rounded = (value * 10).round() / 10;
  return rounded == rounded.roundToDouble()
      ? '${rounded.round()}°'
      : '$rounded°';
}

String _subtitleFor(HaEntity entity) {
  if (entity.isUnavailable) return '応答なし';
  return switch (entity.kind) {
    HaTileKind.toggle => _toggleSubtitle(entity),
    HaTileKind.climate => _climateSubtitle(entity),
    HaTileKind.press => 'タップで実行',
    _ => entity.readout,
  };
}

String _toggleSubtitle(HaEntity entity) {
  if (!entity.isOn) return 'OFF';
  final percent = entity.brightnessPercent;
  return percent == null ? 'ON' : 'ON · $percent%';
}

String _climateSubtitle(HaEntity entity) {
  if (!entity.isOn) return 'OFF';
  final current = entity.currentTemperature;
  final mode = switch (entity.state) {
    'heat' => '暖房',
    'cool' => '冷房',
    'dry' => '除湿',
    'fan_only' => '送風',
    'heat_cool' => '自動',
    'auto' => '自動',
    _ => entity.state,
  };
  return current == null ? mode : '$mode · 室温 ${_formatTemp(current)}';
}

IconData _iconFor(HaEntity entity) {
  return switch (entity.domain) {
    'light' => Icons.lightbulb_outline,
    'switch' => Icons.power_settings_new,
    'input_boolean' => Icons.toggle_on_outlined,
    'automation' => Icons.bolt_outlined,
    'scene' => Icons.auto_awesome_outlined,
    'script' => Icons.play_arrow_outlined,
    'button' => Icons.radio_button_checked,
    'climate' => Icons.ac_unit,
    'binary_sensor' => Icons.sensors,
    'sensor' => switch (entity.deviceClass) {
      'humidity' => Icons.water_drop_outlined,
      _ => Icons.thermostat,
    },
    _ => Icons.device_unknown_outlined,
  };
}
