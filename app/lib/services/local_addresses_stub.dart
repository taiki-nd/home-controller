/// web 用。**探索はできない**ので空を返す。
///
/// 呼び出し側（`WiimDiscovery`）は空なら「見つからなかった」として
/// IP 手入力に倒すので、ここで投げる必要はない。
Future<List<String>> localIPv4Addresses() async => const [];
