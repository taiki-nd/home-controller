/// Home Assistant の状態オブジェクトと、そこから引く表示用の値。
///
/// HA は `entity_id` の前半がドメイン（`light.living` なら `light`）で、
/// できることはドメインで決まる。属性は機種ごとに生えたり生えなかったりするので、
/// **必ず「無い」を通せる形で読む。**
library;

/// タイルの種類。ドメインの数だけ UI を作らない（設計メモ §11）。
enum HaTileKind {
  /// 押すと ON/OFF が入れ替わる。
  toggle,

  /// 押すだけ。状態を持たない。
  press,

  /// ON/OFF と温度±。
  climate,

  /// 押せない。数値を出すだけ。
  readout,

  /// MVP では出さない。
  unsupported,
}

/// MVP で扱うドメイン → タイル種別。
///
/// `fan` / `cover` / `lock` / `media_player` / `vacuum` は入れていない。
/// - `lock` は壁掛けの誤タップで玄関が開くので、確認ステップを設計してから
/// - `media_player` は music 側と役割が混ざるので後回し
/// - 残りは MVP の範囲外（`docs/home-assistant-integration.md` §11）
HaTileKind tileKindFor(String domain) => switch (domain) {
  'light' || 'switch' || 'input_boolean' || 'automation' => HaTileKind.toggle,
  'scene' || 'script' || 'button' => HaTileKind.press,
  'climate' => HaTileKind.climate,
  'sensor' || 'binary_sensor' => HaTileKind.readout,
  _ => HaTileKind.unsupported,
};

/// エンティティ 1 つ。`get_states` の 1 要素と `state_changed` の `new_state`
/// は同じ形なので、どちらもこれで読む。
class HaEntity {
  const HaEntity({
    required this.entityId,
    required this.state,
    required this.attributes,
  });

  factory HaEntity.fromJson(Map<String, dynamic> json) {
    return HaEntity(
      entityId: json['entity_id'] as String,
      state: json['state'] as String? ?? unknownState,
      attributes: Map<String, dynamic>.from(
        json['attributes'] as Map? ?? const {},
      ),
    );
  }

  static const unavailableState = 'unavailable';
  static const unknownState = 'unknown';

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  String get domain => entityId.split('.').first;

  HaTileKind get kind => tileKindFor(domain);

  String get name =>
      attributes['friendly_name'] as String? ?? entityId.split('.').last;

  /// HA が状態を取れていない。**「OFF」と区別する**（消えているのか、
  /// 届いていないのかで、ユーザーがやるべきことが違う）。
  bool get isUnavailable =>
      state == unavailableState || state == unknownState;

  /// 点いているか。`climate` は `off` 以外がすべて運転中なので別扱い。
  bool get isOn {
    if (isUnavailable) return false;
    if (domain == 'climate') return state != 'off';
    return state == 'on';
  }

  /// 0–255。調光できない機種では null。
  int? get brightness => _asInt(attributes['brightness']);

  /// 0–100 に直した明るさ。UI はこちらを使う。
  int? get brightnessPercent {
    final raw = brightness;
    if (raw == null) return null;
    return (raw * 100 / 255).round().clamp(0, 100);
  }

  /// 調光できるか。`supported_color_modes` に明るさを持つモードがあるかで見る。
  /// `onoff` だけの機種にスライダを出さないための判定。
  bool get supportsBrightness {
    final modes = attributes['supported_color_modes'];
    if (modes is! List) return false;
    return modes.any((m) => m != 'onoff' && m != 'unknown');
  }

  /// エアコンの現在温度（室温）。
  double? get currentTemperature => _asDouble(attributes['current_temperature']);

  /// エアコンの設定温度。
  double? get targetTemperature => _asDouble(attributes['temperature']);

  double? get minTemperature => _asDouble(attributes['min_temp']);
  double? get maxTemperature => _asDouble(attributes['max_temp']);

  /// 温度の刻み。無い機種は 0.5 とする（HA の既定と同じ）。
  double get temperatureStep => _asDouble(attributes['target_temp_step']) ?? 0.5;

  /// `off` を除いた運転モード。ON に戻すときにどれを使うか決めるのに要る。
  List<String> get hvacModes {
    final modes = attributes['hvac_modes'];
    if (modes is! List) return const [];
    return modes.whereType<String>().where((m) => m != 'off').toList();
  }

  /// 消したエアコンを点け直すときのモード。
  ///
  /// `heat_cool` / `auto` があればそれ。無ければ最初のモード。
  /// **`climate.turn_on` は機種によっては未実装**なので、`set_hvac_mode` を使う。
  String? get preferredHvacMode {
    final modes = hvacModes;
    if (modes.isEmpty) return null;
    for (final preferred in const ['heat_cool', 'auto']) {
      if (modes.contains(preferred)) return preferred;
    }
    return modes.first;
  }

  String? get unit => attributes['unit_of_measurement'] as String?;

  String? get deviceClass => attributes['device_class'] as String?;

  /// 数値行に出す文字列。単位まで込みで返す。
  String get readout {
    if (isUnavailable) return '—';
    if (domain == 'binary_sensor') return state == 'on' ? '検知' : '—';
    final u = unit;
    return u == null ? state : '$state$u';
  }

  HaEntity copyWith({String? state, Map<String, dynamic>? attributes}) {
    return HaEntity(
      entityId: entityId,
      state: state ?? this.state,
      attributes: attributes ?? this.attributes,
    );
  }

  static int? _asInt(Object? v) => switch (v) {
    int() => v,
    double() => v.round(),
    String() => int.tryParse(v),
    _ => null,
  };

  static double? _asDouble(Object? v) => switch (v) {
    int() => v.toDouble(),
    double() => v,
    String() => double.tryParse(v),
    _ => null,
  };
}

/// 部屋（HA の area）。
class HaRoom {
  const HaRoom({required this.id, required this.name});

  /// area が付いていないエンティティの行き先。
  static const unassignedId = '__unassigned__';

  final String id;
  final String name;
}

/// エンティティがどの部屋にいて、どのラベルを持つか。
///
/// レジストリ（`config/*_registry/list`）は**管理者トークンでないと引けない**。
/// 引けなかったときは空のまま動かす（部屋は 1 つにまとまる）。
class HaRegistry {
  const HaRegistry({
    this.areaNames = const {},
    this.entityAreas = const {},
    this.entityLabels = const {},
  });

  static const empty = HaRegistry();

  /// area_id → 表示名。
  final Map<String, String> areaNames;

  /// entity_id → area_id。エンティティに直接付いていなければ、
  /// 属するデバイスの area を引いて埋めてある。
  final Map<String, String> entityAreas;

  /// entity_id → ラベル id の集合。
  final Map<String, Set<String>> entityLabels;

  bool get isEmpty => areaNames.isEmpty && entityAreas.isEmpty;

  String? areaOf(String entityId) => entityAreas[entityId];

  bool hasLabel(String entityId, String labelId) =>
      entityLabels[entityId]?.contains(labelId) ?? false;

  /// このラベルを持つエンティティが 1 つでもあるか。
  ///
  /// **1 つも無ければラベルでの絞り込みをやめる**（`docs/…` §8 のラベル運用を
  /// まだ設定していない人が、真っ白な画面を見ることになるため）。
  bool anyWithLabel(String labelId) =>
      entityLabels.values.any((labels) => labels.contains(labelId));
}
