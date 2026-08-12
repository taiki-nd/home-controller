import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/ma_models.dart';
import 'ma_credentials.dart';
import 'ws_socket.dart';

/// MA とのやり取りが失敗した。文言はそのまま画面に出す前提で作る。
class MaException implements Exception {
  MaException(this.message);

  final String message;

  @override
  String toString() => 'MaException: $message';
}

/// トークンが拒否された、または要求された。
///
/// **通信断と必ず区別する。** 再接続しても直らないので、リトライを回さずに
/// 設定画面へ戻す（`HaAuthException` と同じ扱い）。
class MaAuthException extends MaException {
  MaAuthException(super.message);
}

/// MA から届いたイベント 1 件。
@immutable
class MaEvent {
  const MaEvent({required this.type, this.objectId, this.data});

  /// `queue_updated` / `queue_time_updated` / `player_updated` など。
  final String type;

  /// player_id / queue_id / uri。
  final String? objectId;

  final Object? data;
}

/// WebSocket 1 本ぶんのセッション。
///
/// 切れたら作り直す。**再接続のループはここに持たない**（`MaController` 側）。
///
/// プロトコルは HA と違う（`docs/music-assistant-integration.md` §2）。
/// 繋ぐとサーバー情報が向こうから飛んでくる → schema 28 以降なら `auth` を
/// 送る → 以降はコマンドに `message_id`（**文字列**）を振り、同じ id の
/// `result` が返る。イベントの購読コマンドは無い（認証が通った時点で
/// サーバー側が勝手に流し始める）。
class MaSession {
  MaSession(this._socket) {
    _sub = _socket.messages.listen(
      _onMessage,
      onError: (Object e) => _finish(MaException('接続が切れました: $e')),
      onDone: () => _finish(MaException('接続が切れました')),
    );
  }

  /// 接続してサーバー情報を受け、必要なら認証まで済ませる。
  static Future<MaSession> connect(
    MaConnection connection, {
    SocketOpener opener = ChannelSocket.open,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final AppSocket socket;
    try {
      socket = await opener(connection.websocketUrl).timeout(timeout);
    } on TimeoutException {
      throw MaException('Music Assistant に接続できませんでした（応答なし）');
    } catch (e) {
      debugPrint('MaSession.connect failed: $e');
      throw MaException('Music Assistant に接続できませんでした');
    }
    final session = MaSession(socket);
    try {
      await session._handshake(connection.token).timeout(timeout);
    } catch (e) {
      await session.close();
      if (e is TimeoutException) {
        throw MaException('Music Assistant が応答しませんでした');
      }
      rethrow;
    }
    return session;
  }

  /// 1 コマンドの待ち時間。壁掛けで固まったままにしないための上限。
  ///
  /// 検索は外部プロバイダを叩くので、ライブラリ操作より時間がかかる。
  static const _requestTimeout = Duration(seconds: 15);
  static const _searchTimeout = Duration(seconds: 30);

  /// 認証系のエラーコード（`music_assistant_models/errors.py`）。
  /// 20 = AuthenticationRequired / 21 = AuthenticationFailed / 23 = InvalidToken。
  static const _authErrorCodes = {20, 21, 23};

  final AppSocket _socket;
  late final StreamSubscription<String> _sub;

  final _pending = <String, Completer<Object?>>{};

  /// `partial: true` で分割されてくる result の受け皿（§2）。
  final _partial = <String, List<Object?>>{};

  final _events = StreamController<MaEvent>.broadcast();
  final _done = Completer<void>();

  Completer<MaServerInfo>? _hello;
  MaServerInfo? _serverInfo;
  int _nextId = 1;
  bool _closed = false;

  /// サーバーから流れてくるイベント。
  Stream<MaEvent> get events => _events.stream;

  /// 接続が終わったら完了する。再接続の合図に使う。
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// 握手で受け取ったサーバー情報。アートワークの URL 組み立てに使う。
  MaServerInfo? get serverInfo => _serverInfo;

  Future<void> _handshake(String token) async {
    final hello = _hello = Completer<MaServerInfo>();
    final info = await hello.future.whenComplete(() => _hello = null);
    _serverInfo = info;
    if (!info.requiresAuth) return;
    if (token.isEmpty) {
      // 空トークンは「認証なしの古いサーバー」向けの逃げ道。この世代では
      // どのコマンドも通らないので、繋がる前に落として設定画面へ倒す。
      throw MaAuthException('このサーバーにはアクセストークンが必要です');
    }
    // ping と違い、認証だけは結果を見る。false が返る余地は無い（失敗は
    // error_code で来る）が、念のため。
    final result = await _request('auth', {'token': token});
    if (result is Map && result['authenticated'] == false) {
      throw MaAuthException('アクセストークンが拒否されました');
    }
  }

  // ── コマンド ────────────────────────────────────────────────────────

  /// プレイヤー一覧。
  Future<List<MaPlayer>> fetchPlayers() async {
    final result = await _request('players/all');
    if (result is! List) throw MaException('プレイヤーの取得に失敗しました');
    return result
        .whereType<Map>()
        .map((e) => MaPlayer.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// キュー一覧。
  Future<List<MaQueue>> fetchQueues() async {
    final result = await _request('player_queues/all');
    if (result is! List) throw MaException('キューの取得に失敗しました');
    return result
        .whereType<Map>()
        .map((e) => MaQueue.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// キューの中身。件数が多いと `partial` で分割されて届く。
  Future<List<MaQueueItem>> fetchQueueItems(
    String queueId, {
    int limit = 100,
    int offset = 0,
  }) async {
    final result = await _request('player_queues/items', {
      'queue_id': queueId,
      'limit': limit,
      'offset': offset,
    });
    if (result is! List) return const [];
    return result.map(MaQueueItem.tryFrom).whereType<MaQueueItem>().toList();
  }

  /// 全プロバイダ横断の検索。
  Future<MaSearchResults> search(
    String query, {
    List<String> mediaTypes = const ['track', 'album', 'playlist'],
    int limit = 20,
  }) async {
    final result = await _request('music/search', {
      'search_query': query,
      'media_types': mediaTypes,
      'limit': limit,
    }, _searchTimeout);
    if (result is! Map) throw MaException('検索に失敗しました');
    return MaSearchResults.fromJson(Map<String, dynamic>.from(result));
  }

  /// キューに積む / いま鳴らす。
  Future<void> playMedia(
    String queueId,
    String uri, {
    MaQueueOption option = MaQueueOption.add,
  }) => _request('player_queues/play_media', {
    'queue_id': queueId,
    'media': uri,
    'option': option.wire,
  });

  Future<void> playPause(String queueId) =>
      _request('player_queues/play_pause', {'queue_id': queueId});

  Future<void> next(String queueId) =>
      _request('player_queues/next', {'queue_id': queueId});

  Future<void> previous(String queueId) =>
      _request('player_queues/previous', {'queue_id': queueId});

  Future<void> seek(String queueId, Duration position) => _request(
    'player_queues/seek',
    {'queue_id': queueId, 'position': position.inSeconds},
  );

  Future<void> setShuffle(String queueId, bool enabled) => _request(
    'player_queues/shuffle',
    {'queue_id': queueId, 'shuffle_enabled': enabled},
  );

  Future<void> setRepeat(String queueId, MaRepeatMode mode) => _request(
    'player_queues/repeat',
    {'queue_id': queueId, 'repeat_mode': mode.wire},
  );

  /// キューの n 番目へ飛ぶ。
  Future<void> playIndex(String queueId, int index) => _request(
    'player_queues/play_index',
    {'queue_id': queueId, 'index': index},
  );

  /// キューから 1 曲外す。
  Future<void> deleteItem(String queueId, String queueItemId) => _request(
    'player_queues/delete_item',
    {'queue_id': queueId, 'item_id_or_index': queueItemId},
  );

  Future<void> clearQueue(String queueId) =>
      _request('player_queues/clear', {'queue_id': queueId});

  /// 音量（0–100）。キューではなくプレイヤーに送る。
  Future<void> setVolume(String playerId, int level) => _request(
    'players/cmd/volume_set',
    {'player_id': playerId, 'volume_level': level.clamp(0, 100)},
  );

  // ── 配送 ────────────────────────────────────────────────────────────

  Future<Object?> _request(
    String command, [
    Map<String, Object?> args = const {},
    Duration? timeout,
  ]) {
    if (_closed) throw MaException('接続が切れています');
    final id = '${_nextId++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _socket.send(
      jsonEncode({'message_id': id, 'command': command, 'args': args}),
    );
    return completer.future.timeout(
      timeout ?? _requestTimeout,
      onTimeout: () {
        _pending.remove(id);
        _partial.remove(id);
        throw MaException('Music Assistant が応答しませんでした');
      },
    );
  }

  void _onMessage(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);

    // イベント。message_id を持たないので先に判定する。
    final event = message['event'];
    if (event is String) {
      _events.add(
        MaEvent(
          type: event,
          objectId: message['object_id'] as String?,
          data: message['data'],
        ),
      );
      return;
    }

    final id = message['message_id'];
    if (id is! String) {
      // 頼まずに飛んでくるのはサーバー情報だけ。
      final info = MaServerInfo.tryFrom(message);
      final hello = _hello;
      if (info != null && hello != null && !hello.isCompleted) {
        hello.complete(info);
      }
      return;
    }

    final code = message['error_code'];
    if (code is int) {
      final detail = message['details'] as String?;
      final error = _authErrorCodes.contains(code)
          ? MaAuthException(detail ?? 'アクセストークンが拒否されました')
          : MaException(detail ?? 'コマンドが失敗しました');
      // オンボーディング未完了のサーバーは、どのコマンドにも紐づかない
      // `message_id: "connection"` で 503 を投げて即切る（§2）。
      final completer = _pending.remove(id);
      _partial.remove(id);
      if (completer == null) {
        final hello = _hello;
        if (hello != null && !hello.isCompleted) hello.completeError(error);
        return;
      }
      completer.completeError(error);
      return;
    }

    if (!message.containsKey('result')) return;
    final result = message['result'];
    if (message['partial'] == true) {
      // 続きが来る。溜めるだけ。
      if (result is List) _partial.putIfAbsent(id, () => []).addAll(result);
      return;
    }
    final completer = _pending.remove(id);
    final buffered = _partial.remove(id);
    if (completer == null) return;
    if (buffered != null && result is List) {
      completer.complete([...buffered, ...result]);
    } else {
      completer.complete(result);
    }
  }

  /// 接続が終わった。待っている呼び出しを全部落としてから閉じる。
  void _finish(MaException reason) {
    if (_closed) return;
    _closed = true;
    final hello = _hello;
    if (hello != null && !hello.isCompleted) hello.completeError(reason);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) completer.completeError(reason);
    }
    _pending.clear();
    _partial.clear();
    if (!_done.isCompleted) _done.complete();
    _events.close();
    _sub.cancel();
  }

  Future<void> close() async {
    _finish(MaException('切断しました'));
    await _socket.close();
  }
}
