import 'package:flutter/material.dart';

import '../../models/ha_models.dart';
import '../../state/home_controller.dart';
import '../../theme/tokens.dart';
import '../widgets/atoms.dart';
import '../widgets/overlays.dart';
import '../widgets/soft_surface.dart';
import 'ha_setup_screen.dart';
import 'widgets/home_tiles.dart';

/// home モードの画面。
///
/// music 側が「左に大判アートワーク・右にレール」なので、こちらは**鏡像**に
/// して左に部屋レール・右にタイルを置く。左右の重心が同じだと、完全分離した
/// 感じが出ない（`docs/home-assistant-integration.md` §10）。
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.onOpenMenu,
  });

  final HomeController controller;

  /// Drawer を開く。**単独の常時アイコンを増やさない**ため、レールの見出しの
  /// 行に同居させる。
  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.needsSetup) {
          return HaSetupScreen(controller: controller, onOpenMenu: onOpenMenu);
        }
        final wide = MediaQuery.sizeOf(context).width >= kTabletBreakpoint;
        final topPad = MediaQuery.paddingOf(context).top;

        return Scaffold(
          backgroundColor: AppColors.frameBg,
          body: Column(
            children: [
              if (controller.errorBanner != null)
                Padding(
                  padding: EdgeInsets.only(top: topPad),
                  child: ErrorBanner(
                    message: controller.errorBanner!,
                    onDismiss: controller.dismissError,
                  ),
                ),
              Expanded(
                child: wide
                    ? _WideBody(controller: controller, onOpenMenu: onOpenMenu)
                    : _NarrowBody(
                        controller: controller,
                        onOpenMenu: onOpenMenu,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _WideBody extends StatelessWidget {
  const _WideBody({required this.controller, required this.onOpenMenu});

  final HomeController controller;
  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.paddingOf(context).top;
    return Row(
      children: [
        SizedBox(
          width: RoomRail.width,
          // レールと本体の境目に線を引かない。面の色を繋いで区切る
          // （music 側のレールと同じ理由 = 焼きつき）。
          child: SoftSurface(
            color: AppColors.white(0.03),
            edges: const [AxisDirection.right],
            child: Padding(
              padding: EdgeInsets.only(top: topPad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _RailHeader(onOpenMenu: onOpenMenu),
                  Expanded(
                    child: RoomRail(
                      rooms: controller.rooms,
                      selectedId: controller.selectedRoomId,
                      onSelect: controller.selectRoom,
                      hasOn: controller.roomHasOn,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(top: topPad),
            child: _RoomBody(controller: controller, columns: 3),
          ),
        ),
      ],
    );
  }
}

class _NarrowBody extends StatelessWidget {
  const _NarrowBody({required this.controller, required this.onOpenMenu});

  final HomeController controller;
  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    final rooms = controller.rooms;
    final selected = controller.selectedRoomId;
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RailHeader(onOpenMenu: onOpenMenu),
          if (rooms.length > 1)
            SizedBox(
              height: 52,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                itemCount: rooms.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final room = rooms[index];
                  final active = room.id == selected;
                  return GestureDetector(
                    onTap: () => controller.selectRoom(room.id),
                    child: Container(
                      alignment: Alignment.center,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        borderRadius: AppRadius.pill,
                        color: active
                            ? AppColors.white(0.14)
                            : AppColors.white(0.05),
                      ),
                      child: Text(
                        room.name,
                        style: AppText.body(
                          14,
                          weight: active ? FontWeight.w900 : FontWeight.w500,
                          color: active ? Colors.white : AppColors.white(0.6),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          Expanded(child: _RoomBody(controller: controller, columns: 2)),
        ],
      ),
    );
  }
}

class _RailHeader extends StatelessWidget {
  const _RailHeader({required this.onOpenMenu});

  final VoidCallback onOpenMenu;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 20, 6),
      child: Row(
        children: [
          MenuButton(onPressed: onOpenMenu),
          const SizedBox(width: 2),
          const CapsLabel('HOME'),
        ],
      ),
    );
  }
}

class _RoomBody extends StatelessWidget {
  const _RoomBody({required this.controller, required this.columns});

  final HomeController controller;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final tiles = controller.tiles;
    final readouts = controller.readouts;

    if (tiles.isEmpty && readouts.isEmpty) {
      return _EmptyState(controller: controller);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.fromLTRB(20, 14, 24, 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisSpacing: 14,
              crossAxisSpacing: 14,
              // 壁掛けで指が届く大きさを優先する。詰め込まない。
              mainAxisExtent: HomeTile.height,
            ),
            itemCount: tiles.length,
            itemBuilder: (context, index) {
              final entity = tiles[index];
              return HomeTile(
                entity: entity,
                onTap: () => _onTap(entity),
                onLongPress: _canDim(entity)
                    ? () => _openBrightness(context, entity)
                    : null,
                onNudge: (steps) => controller.nudgeTemperature(entity, steps),
              );
            },
          ),
        ),
        if (readouts.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 24, 18),
            child: SensorReadouts(entities: readouts),
          ),
      ],
    );
  }

  void _onTap(HaEntity entity) {
    if (entity.kind == HaTileKind.press) {
      controller.press(entity);
    } else {
      controller.toggle(entity);
    }
  }

  bool _canDim(HaEntity entity) =>
      entity.domain == 'light' && entity.supportsBrightness;

  /// 調光はタイルの中ではなくシートに逃がす。壁掛けの iPad でタイル内スライダを
  /// 指で動かすのは、隣のタイルを触る事故が多い。
  Future<void> _openBrightness(BuildContext context, HaEntity entity) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.dialog),
      builder: (context) => _BrightnessSheet(
        entity: entity,
        onChanged: (value) =>
            controller.setBrightnessPercent(entity, value),
      ),
    );
  }
}

class _BrightnessSheet extends StatefulWidget {
  const _BrightnessSheet({required this.entity, required this.onChanged});

  final HaEntity entity;
  final ValueChanged<int> onChanged;

  @override
  State<_BrightnessSheet> createState() => _BrightnessSheetState();
}

class _BrightnessSheetState extends State<_BrightnessSheet> {
  late double _value = (widget.entity.brightnessPercent ?? 0).toDouble();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.entity.name,
              style: AppText.body(18, weight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            CapsLabel('明るさ ${_value.round()}%'),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: AppColors.homeGlow,
                thumbColor: Colors.white,
                inactiveTrackColor: AppColors.white(0.14),
              ),
              child: Slider(
                value: _value,
                max: 100,
                // 動かしている最中に毎フレーム投げると HA を叩きすぎる。
                // 指を離したときだけ送る。
                onChanged: (v) => setState(() => _value = v),
                onChangeEnd: (v) => widget.onChanged(v.round()),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.controller});

  final HomeController controller;

  @override
  Widget build(BuildContext context) {
    final connecting = controller.status == HaStatus.connecting;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const SizedBox.square(
                dimension: 26,
                child: CircularProgressIndicator(
                  color: AppColors.homeGlow,
                  strokeWidth: 2.5,
                ),
              )
            else ...[
              Text(
                controller.status == HaStatus.offline
                    ? 'Home Assistant に繋がっていません'
                    : '表示できる機器がありません',
                textAlign: TextAlign.center,
                style: AppText.body(16, weight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Text(
                controller.status == HaStatus.offline
                    ? '接続が戻れば自動でやり直します。'
                    : 'HA 側で機器に「${HomeController.labelId}」ラベルを付けると、'
                          'ここに出す機器を選べます。',
                textAlign: TextAlign.center,
                style: AppText.body(
                  13,
                  color: AppColors.white(0.6),
                  height: 1.7,
                ),
              ),
              const SizedBox(height: 18),
              OutlineButton(label: '再試行', onPressed: controller.retry),
            ],
          ],
        ),
      ),
    );
  }
}
