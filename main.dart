import 'dart:async';
import 'dart:convert';
import 'dart:io' show WebSocket;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
import 'package:home_widget/home_widget.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ===================================================================
// 数据来源：京东金融浙商银行积存金（非官方公开接口，可能随时变动）
// ===================================================================
const String _sku = '1961543816';
const String _apiUrl =
    'https://api.jdjygold.com/gw2/generic/jrm/h5/m/stdLatestPrice';
const Duration _timeout = Duration(seconds: 4);

const Map<String, String> _headers = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/120.0 Mobile Safari/537.36',
  'Accept': 'application/json',
};

// 复用同一个 HTTP 连接（keep-alive），避免每秒一次的请求每次都重新做 TLS 握手
final http.Client _client = http.Client();

double? _toDouble(dynamic v) =>
    v == null ? null : double.tryParse(v.toString());
String _two(int n) => n.toString().padLeft(2, '0');
String _fmt(double v) => v.toStringAsFixed(2);

String _changeText(double? change, String? rate) => [
      if (change != null) '${change >= 0 ? '+' : ''}${_fmt(change)}',
      if (rate != null) rate,
    ].join('   ');

String _pctText(double? r) =>
    r == null ? '' : '${r >= 0 ? '+' : ''}${r.toStringAsFixed(2)}%';

String _cleanError(Object? e) {
  if (e is TimeoutException) return '请求超时';
  final s = e?.toString() ?? '未知错误';
  if (s.contains('SocketException') || s.contains('ClientException')) {
    return '网络不可用';
  }
  return s.replaceFirst('Exception: ', '');
}

class GoldQuote {
  final double price; // 元/克
  final double? change; // 涨跌额
  final String? rate; // 涨跌幅（原样显示）
  final Map<String, dynamic> raw; // 接口原始字段

  GoldQuote(this.price, this.change, this.rate, this.raw);
}

Map<String, dynamic>? _extractDatas(http.Response res) {
  if (res.statusCode != 200) return null;
  try {
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final datas = body['resultData']?['datas'];
    if (datas is Map && datas['price'] != null) {
      return Map<String, dynamic>.from(datas);
    }
  } catch (_) {}
  return null;
}

// 记住哪种请求方式成功过，避免每秒都先失败一次
bool _preferPost = false;

Future<GoldQuote> fetchQuote() async {
  Object? lastError;
  for (var i = 0; i < 2; i++) {
    final usePost = i == 0 ? _preferPost : !_preferPost;
    try {
      final http.Response res = usePost
          ? await _client
              .post(Uri.parse(_apiUrl),
                  headers: _headers, body: {'productSku': _sku})
              .timeout(_timeout)
          : await _client
              .get(Uri.parse('$_apiUrl?productSku=$_sku'), headers: _headers)
              .timeout(_timeout);
      final datas = _extractDatas(res);
      if (datas != null) {
        final price = _toDouble(datas['price']);
        if (price == null) throw Exception('价格字段无法解析');
        _preferPost = usePost;
        return GoldQuote(
          price,
          _toDouble(datas['upAndDownAmt']),
          datas['upAndDownRate']?.toString(),
          datas,
        );
      }
      lastError = '接口返回格式异常（HTTP ${res.statusCode}）';
    } catch (e) {
      lastError = e;
    }
  }
  throw Exception(_cleanError(lastError));
}

// ===================================================================
// 伦敦金（现货黄金，美元/盎司）：新浪财经行情 hf_XAU（非官方接口）
// 字段：0 最新价 … 4 最高 5 最低 6 行情时间 7 昨收 8 开盘
// ===================================================================
const Duration _ldnTimeout = Duration(seconds: 2);
bool _ldnPlainUrl = false; // 记住哪种地址写法可用

class LondonQuote {
  final double price;
  final double? change; // 涨跌额（相对昨收）
  final double? ratePct; // 涨跌幅 %
  final double? high;
  final double? low;
  final String? quoteTime;
  final String raw;
  final double? prevClose; // 昨收（来自新浪，用来计算涨跌）
  final String source; // 'ws' 京东实时推送 / 'sina' 新浪备用行情

  LondonQuote(this.price, this.change, this.ratePct, this.high, this.low,
      this.quoteTime, this.raw,
      {this.prevClose, this.source = 'sina'});
}

Future<LondonQuote> fetchLondon() async {
  Object? lastError;
  for (var i = 0; i < 2; i++) {
    final plain = i == 0 ? _ldnPlainUrl : !_ldnPlainUrl;
    try {
      final uri = plain
          ? Uri.parse('https://hq.sinajs.cn/list=hf_XAU')
          // 带时间戳，避免中间缓存导致拿到旧数据
          : Uri.parse(
              'https://hq.sinajs.cn/?_=${DateTime.now().millisecondsSinceEpoch}&list=hf_XAU');
      final q = await _fetchLondonFrom(uri);
      _ldnPlainUrl = plain;
      return q;
    } catch (e) {
      lastError = e;
    }
  }
  throw Exception(_cleanError(lastError));
}

Future<LondonQuote> _fetchLondonFrom(Uri uri) async {
  final http.Response res = await _client.get(
    uri,
    headers: {
      'Referer': 'https://finance.sina.com.cn',
      'User-Agent': _headers['User-Agent']!,
      'Cache-Control': 'no-cache',
    },
  ).timeout(_ldnTimeout);
  if (res.statusCode != 200) {
    throw Exception('伦敦金接口 HTTP ${res.statusCode}');
  }
  // 返回为 GBK 编码，这里只取数字字段，用 latin1 解码即可
  final text = latin1.decode(res.bodyBytes);
  final m = RegExp(r'"([^"]*)"').firstMatch(text);
  final f = (m?.group(1) ?? '').split(',');
  if (f.length < 9) throw Exception('伦敦金数据为空或格式异常');

  final price = _toDouble(f[0]);
  if (price == null || price <= 0) throw Exception('伦敦金价格无法解析');

  double? change;
  double? ratePct;
  final prev = _toDouble(f[7]);
  if (prev != null && prev > 0) {
    final c = price - prev;
    final r = c / prev * 100;
    if (r.abs() < 15) {
      // 数值明显不合理时不显示涨跌，避免字段对应错误
      change = c;
      ratePct = r;
    }
  }
  double? high = _toDouble(f[4]);
  double? low = _toDouble(f[5]);
  if (high == null || low == null || high < low) {
    high = null;
    low = null;
  }
  return LondonQuote(
      price, change, ratePct, high, low, f[6].trim(), text.trim(),
      prevClose: prev, source: 'sina');
}

// ===================================================================
// 伦敦金实时推送：京东金融行情 WebSocket（非官方）
// 1) 从 getDomainInfo 取加密的服务器列表，AES-256-CBC 解密得到 hq_ws_links
// 2) 连接后服务器会持续推送 [{"symbol":"GOLD","bid":..,"ask":..}]
// ===================================================================
const String _wsDomainApi = 'https://www.jrjr.com/api/getDomainInfo';
const String _wsFallback =
    'wss://alb-1ko0lowmvacsqia0ij.cn-shenzhen.alb.aliyuncsslb.com:26203';
const String _wsKeyB64 = 'JkiBZH1JS2QH2gNpweehCAiUJzOgIwvIqsndqGGgu8E=';

Future<String> fetchWsUrl() async {
  final res = await _client.get(
    Uri.parse(_wsDomainApi),
    headers: {
      'Accept': 'application/json',
      'User-Agent': _headers['User-Agent']!,
    },
  ).timeout(const Duration(seconds: 5));
  if (res.statusCode != 200) {
    throw Exception('获取推送地址失败 HTTP ${res.statusCode}');
  }
  final body = jsonDecode(utf8.decode(res.bodyBytes));
  final enData = body['data']?['en_data'];
  if (body['code'] != 0 || enData is! String) {
    throw Exception('推送地址响应格式异常');
  }
  final all = base64Decode(enData);
  if (all.length <= 16) throw Exception('推送地址数据异常');
  // 前 16 字节是 IV，后面是密文
  final encrypter = enc.Encrypter(
    enc.AES(enc.Key(base64Decode(_wsKeyB64)), mode: enc.AESMode.cbc),
  );
  final plain = encrypter.decrypt(
    enc.Encrypted(Uint8List.fromList(all.sublist(16))),
    iv: enc.IV(Uint8List.fromList(all.sublist(0, 16))),
  );
  final cfg = jsonDecode(plain);
  final links = cfg['hq_ws_links'];
  if (links is Map && links.isNotEmpty && links.values.first != null) {
    return links.values.first.toString();
  }
  throw Exception('推送地址为空');
}

// ===================================================================
// 后台服务：每秒取价、触发提醒
// ===================================================================
// ===================================================================
// 支撑 / 阻力（统计估算，不是预测）
// 思路：在所选时间窗口内，把价格分成 40 档，综合两项指标给每一档打分——
//   1) 价格在该档停留的时间（成交密集区，类似“筹码分布”）
//   2) 反复在该档附近见顶/见底的次数（越新的权重越大），区间最高/最低额外加分
// 现价上方得分最高的一档 = 最强阻力，下方得分最高的一档 = 最强支撑
// ===================================================================
Map<String, dynamic> computeSr(
    List<int> ts, List<double> px, int windowMin, double price) {
  final res = <String, dynamic>{'minutes': windowMin, 'ok': false, 'have': 0};
  if (ts.isEmpty) return res;
  final from = ts.last - windowMin * 60;
  var start = 0;
  while (start < ts.length && ts[start] < from) {
    start++;
  }
  final n = ts.length - start;
  if (n < 2) return res;
  final haveSec = ts.last - ts[start];
  res['have'] = haveSec ~/ 60;
  if (n < 20 || haveSec < 180) return res; // 至少 3 分钟数据

  var hi = px[start];
  var lo = px[start];
  for (var i = start; i < ts.length; i++) {
    if (px[i] > hi) hi = px[i];
    if (px[i] < lo) lo = px[i];
  }
  res['hi'] = hi;
  res['lo'] = lo;
  res['ok'] = true;
  final range = hi - lo;
  if (range < 0.02) {
    res['flat'] = true; // 这段时间价格几乎没动
    return res;
  }

  const bins = 40;
  final bw = range / bins;
  int binOf(double v) {
    final b = ((v - lo) / bw).floor();
    return b < 0 ? 0 : (b >= bins ? bins - 1 : b);
  }

  // 1) 停留时间密度
  final dens = List<double>.filled(bins, 0);
  final sum = List<double>.filled(bins, 0);
  for (var i = start; i < ts.length; i++) {
    final b = binOf(px[i]);
    dens[b] += 1;
    sum[b] += px[i];
  }
  final sm = List<double>.filled(bins, 0);
  for (var b = 0; b < bins; b++) {
    var v = dens[b] * 2;
    var w = 2.0;
    if (b > 0) {
      v += dens[b - 1];
      w += 1;
    }
    if (b < bins - 1) {
      v += dens[b + 1];
      w += 1;
    }
    sm[b] = v / w;
  }
  final maxD = sm.reduce(math.max);

  // 2) 摆动高点 / 低点（把窗口切成若干段，找比前后各两段都高/低的点）
  var seg = haveSec ~/ 30;
  if (seg < 6) seg = 6;
  if (seg > 48) seg = 48;
  final segHi = List<double>.filled(seg, double.negativeInfinity);
  final segLo = List<double>.filled(seg, double.infinity);
  for (var i = start; i < ts.length; i++) {
    var k = ((ts[i] - ts[start]) * seg) ~/ (haveSec + 1);
    if (k >= seg) k = seg - 1;
    if (px[i] > segHi[k]) segHi[k] = px[i];
    if (px[i] < segLo[k]) segLo[k] = px[i];
  }
  final touch = List<double>.filled(bins, 0);
  for (var k = 2; k < seg - 2; k++) {
    if (segHi[k].isInfinite || segLo[k].isInfinite) continue;
    final rec = 0.5 + 0.5 * k / seg; // 越新权重越大
    var isHigh = true;
    var isLow = true;
    for (final j in const [-2, -1, 1, 2]) {
      if (segHi[k + j] > segHi[k]) isHigh = false;
      if (segLo[k + j] < segLo[k]) isLow = false;
    }
    if (isHigh) touch[binOf(segHi[k])] += rec;
    if (isLow) touch[binOf(segLo[k])] += rec;
  }

  final hiBin = binOf(hi);
  final loBin = binOf(lo);
  final score = List<double>.filled(bins, 0);
  for (var b = 0; b < bins; b++) {
    score[b] = touch[b] + 2.0 * (maxD > 0 ? sm[b] / maxD : 0);
  }
  score[hiBin] += 1.0; // 区间最高/最低本身就是天然的阻力/支撑
  score[loBin] += 1.0;
  final maxS = score.reduce(math.max);

  double levelOf(int b) {
    if (b == hiBin) return hi;
    if (b == loBin) return lo;
    return dens[b] > 0 ? sum[b] / dens[b] : lo + (b + 0.5) * bw;
  }

  bool better(int b, int? cur, bool up) {
    if (cur == null) return true;
    final d = score[b] - score[cur];
    if (d.abs() > 1e-9) return d > 0;
    return up ? levelOf(b) < levelOf(cur) : levelOf(b) > levelOf(cur);
  }

  int? bestUp;
  int? bestDn;
  for (var b = 0; b < bins; b++) {
    if (score[b] < 0.3) continue;
    final lv = levelOf(b);
    if (lv > price + bw * 0.5) {
      if (better(b, bestUp, true)) bestUp = b;
    } else if (lv < price - bw * 0.5) {
      if (better(b, bestDn, false)) bestDn = b;
    }
  }
  if (bestUp != null) {
    res['res'] = levelOf(bestUp);
    res['resStr'] = score[bestUp] / maxS;
  }
  if (bestDn != null) {
    res['sup'] = levelOf(bestDn);
    res['supStr'] = score[bestDn] / maxS;
  }
  return res;
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorHandler());
}

class MonitorHandler extends TaskHandler {
  final fln.FlutterLocalNotificationsPlugin _notif =
      fln.FlutterLocalNotificationsPlugin();
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  bool _busy = false;
  bool _busyLdn = false;
  DateTime _ldnBackoffUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fast = true; // App 在前台：每秒；在后台：每 5 秒
  int _tick = 0;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);

  GoldQuote? _zs;
  LondonQuote? _ldn;

  // 浙商价格历史（每 5 秒采样一次，保留约 13 小时），用于计算支撑/阻力
  final List<int> _hTs = [];
  final List<double> _hPx = [];
  DateTime _lastSample = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastHistSave = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastSrCalc = DateTime.fromMillisecondsSinceEpoch(0);
  bool _histDirty = false;

  // 伦敦金：京东实时推送（主）+ 新浪（昨收/最高最低/备用）
  WebSocket? _ws;
  bool _wsConnecting = false;
  int _wsFail = 0;
  DateTime _wsNextTry = DateTime.fromMillisecondsSinceEpoch(0);
  String _wsStatus = '未连接';
  double? _wsBid;
  DateTime? _wsAt;
  String? _wsRaw;
  LondonQuote? _sinaBase;
  DateTime _lastLdnSend = DateTime.fromMillisecondsSinceEpoch(0);

  bool get _wsFresh =>
      _wsBid != null &&
      _wsAt != null &&
      DateTime.now().difference(_wsAt!).inSeconds < 10;

  bool _upOn = false;
  bool _downOn = false;
  double? _upPrice;
  double? _downPrice;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    try {
      await _notif.initialize(
        settings: const fln.InitializationSettings(
          android: fln.AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
    } catch (_) {}
    await _loadSettings();
    await _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final raw = await _prefs.getString('hist');
      if (raw == null || raw.isEmpty) return;
      final cutoff = DateTime.now().millisecondsSinceEpoch ~/ 1000 - 13 * 3600;
      for (final item in raw.split(';')) {
        final i = item.indexOf(',');
        if (i <= 0) continue;
        final t = int.tryParse(item.substring(0, i));
        final p = double.tryParse(item.substring(i + 1));
        if (t == null || p == null || t < cutoff) continue;
        if (_hTs.isNotEmpty && t <= _hTs.last) continue;
        _hTs.add(t);
        _hPx.add(p);
      }
    } catch (_) {}
  }

  Future<void> _saveHistory() async {
    _lastHistSave = DateTime.now();
    if (!_histDirty) return;
    _histDirty = false;
    try {
      final sb = StringBuffer();
      for (var i = 0; i < _hTs.length; i++) {
        if (i > 0) sb.write(';');
        sb.write(_hTs[i]);
        sb.write(',');
        sb.write(_hPx[i].toStringAsFixed(2));
      }
      await _prefs.setString('hist', sb.toString());
    } catch (_) {}
  }

  void _recordSample(double p) {
    final now = DateTime.now();
    if (now.difference(_lastSample).inSeconds < 5) return;
    _lastSample = now;
    final t = now.millisecondsSinceEpoch ~/ 1000;
    // 中间断了超过 15 分钟（服务被关/手机休眠），旧数据不连续，丢弃重新积累
    if (_hTs.isNotEmpty && t - _hTs.last > 15 * 60) {
      _hTs.clear();
      _hPx.clear();
    }
    _hTs.add(t);
    _hPx.add(p);
    final cutoff = t - 13 * 3600;
    var k = 0;
    while (k < _hTs.length && _hTs[k] < cutoff) {
      k++;
    }
    if (k > 0) {
      _hTs.removeRange(0, k);
      _hPx.removeRange(0, k);
    }
    _histDirty = true;
    if (now.difference(_lastHistSave).inSeconds >= 120) _saveHistory();
    if (_fast && now.difference(_lastSrCalc).inSeconds >= 5) {
      _lastSrCalc = now;
      final out = [
        for (final m in const [30, 60, 240, 720]) computeSr(_hTs, _hPx, m, p),
      ];
      FlutterForegroundTask.sendDataToMain(
          {'type': 'sr', 'json': jsonEncode(out)});
    }
  }

  Future<void> _loadSettings() async {
    _upOn = await _prefs.getBool('up_on') ?? false;
    _downOn = await _prefs.getBool('down_on') ?? false;
    _upPrice = await _prefs.getDouble('up_price');
    _downPrice = await _prefs.getDouble('down_price');
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _tick++;
    // 浙商：前台每秒，后台每 5 秒
    if (!_busy && (_fast || _tick % 5 == 0)) _poll();
    // 伦敦金实时推送：长时间没数据就主动重连；断开时自动重连
    final at = _wsAt;
    if (_ws != null &&
        at != null &&
        DateTime.now().difference(at).inSeconds > 30) {
      _ws?.close();
      _ws = null;
      _wsAt = null;
      _wsStatus = '长时间无数据，重连中';
    }
    if (_ws == null) _ensureWs();
    // 新浪行情只用来取昨收/最高最低；推送正常时放慢，推送断开时当备用行情
    final sinaEvery = _wsFresh ? (_fast ? 15 : 30) : (_fast ? 3 : 15);
    if (!_busyLdn &&
        DateTime.now().isAfter(_ldnBackoffUntil) &&
        (_tick - 1) % sinaEvery == 0) {
      _pollLondon();
    }
  }

  Future<void> _ensureWs() async {
    if (_ws != null || _wsConnecting) return;
    if (DateTime.now().isBefore(_wsNextTry)) return;
    _wsConnecting = true;
    try {
      String url;
      try {
        url = await fetchWsUrl();
      } catch (_) {
        url = _wsFallback;
      }
      final sock =
          await WebSocket.connect(url).timeout(const Duration(seconds: 8));
      _ws = sock;
      _wsFail = 0;
      _wsStatus = '已连接';
      sock.listen(
        _onWsMessage,
        onDone: () => _onWsClosed(sock),
        onError: (_) => _onWsClosed(sock),
        cancelOnError: true,
      );
    } catch (e) {
      _wsFail++;
      _wsStatus = '连接失败：${_cleanError(e)}';
      _wsNextTry = DateTime.now()
          .add(Duration(seconds: _wsFail < 10 ? _wsFail * 3 : 30));
    } finally {
      _wsConnecting = false;
    }
  }

  void _onWsClosed(WebSocket sock) {
    if (identical(_ws, sock)) _ws = null;
    _wsStatus = '已断开，重连中';
    _wsNextTry = DateTime.now().add(const Duration(seconds: 3));
  }

  void _onWsMessage(dynamic message) {
    try {
      final text =
          message is String ? message : utf8.decode(message as List<int>);
      final data = jsonDecode(text);
      if (data is! List) return;
      for (final e in data) {
        if (e is Map && e['symbol'] == 'GOLD') {
          final bid = _toDouble(e['bid']);
          if (bid == null || bid <= 0) return;
          _wsBid = bid; // 使用买入价
          _wsAt = DateTime.now();
          _wsRaw = text.length > 500 ? text.substring(0, 500) : text;
          _onLondonTick();
          return;
        }
      }
    } catch (_) {}
  }

  // 合成最新伦敦金：实时价来自推送，涨跌按新浪的昨收计算
  LondonQuote? _composeLondon() {
    final base = _sinaBase;
    final fresh = _wsFresh;
    if (!fresh && base == null) return null;
    final price = fresh ? _wsBid! : base!.price;
    final prev = base?.prevClose;
    double? change = base?.change;
    double? rate = base?.ratePct;
    if (fresh) {
      change = null;
      rate = null;
      if (prev != null && prev > 0) {
        final c = price - prev;
        final r = c / prev * 100;
        if (r.abs() < 15) {
          change = c;
          rate = r;
        }
      }
    }
    double? high = base?.high;
    double? low = base?.low;
    if (high != null && low != null) {
      if (price > high) high = price;
      if (price < low) low = price;
    }
    final at = _wsAt;
    return LondonQuote(
      price,
      change,
      rate,
      high,
      low,
      fresh && at != null
          ? '${_two(at.hour)}:${_two(at.minute)}:${_two(at.second)}'
          : base?.quoteTime,
      'WS[$_wsStatus]: ${_wsRaw ?? '-'}\nSina: ${base?.raw ?? '-'}',
      prevClose: prev,
      source: fresh ? 'ws' : 'sina',
    );
  }

  void _onLondonTick() {
    final q = _composeLondon();
    if (q == null) return;
    _ldn = q;
    final now = DateTime.now();
    if (now.difference(_lastLdnSend).inMilliseconds >= (_fast ? 250 : 5000)) {
      _lastLdnSend = now;
      FlutterForegroundTask.sendDataToMain({
        'type': 'ldn',
        'price': q.price,
        'change': q.change,
        'rate': q.ratePct,
        'high': q.high,
        'low': q.low,
        'time': q.quoteTime,
        'raw': q.raw,
        'source': q.source,
      });
    }
    _publish();
  }

  Future<void> _poll() async {
    _busy = true;
    try {
      final q = await fetchQuote();
      _zs = q;
      _recordSample(q.price);
      await _checkAlerts(q.price);

      FlutterForegroundTask.sendDataToMain({
        'type': 'quote',
        'price': q.price,
        'change': q.change,
        'rate': q.rate,
        'raw': jsonEncode(q.raw),
      });

      _publish();
    } catch (e) {
      FlutterForegroundTask.sendDataToMain(
          {'type': 'error', 'msg': _cleanError(e)});
    } finally {
      _busy = false;
    }
  }

  Future<void> _pollLondon() async {
    _busyLdn = true;
    try {
      _sinaBase = await fetchLondon();
      _onLondonTick();
    } catch (e) {
      _ldnBackoffUntil = DateTime.now().add(const Duration(seconds: 2));
      if (!_wsFresh) {
        FlutterForegroundTask.sendDataToMain(
            {'type': 'ldnError', 'msg': _cleanError(e)});
      }
    } finally {
      _busyLdn = false;
    }
  }

  // 更新常驻通知和桌面小组件（最多每 3 秒一次）
  void _publish() {
    final now = DateTime.now();
    if (now.difference(_lastPublish).inSeconds < 3) return;
    _lastPublish = now;
    final zs = _zs;
    final ld = _ldn;
    FlutterForegroundTask.updateService(
      notificationTitle:
          zs == null ? '浙商金价监控中' : '浙商 ${_fmt(zs.price)} 元/克',
      notificationText: ld == null
          ? '伦敦金 --'
          : '伦敦金 ${_fmt(ld.price)}  ${_pctText(ld.ratePct)}',
    );
    _updateWidget();
  }

  Future<void> _updateWidget() async {
    try {
      final zs = _zs;
      final ld = _ldn;
      final now = DateTime.now();
      Future<void> put(String k, String v) =>
          HomeWidget.saveWidgetData<String>(k, v);
      await put('zs_price', zs == null ? '--' : _fmt(zs.price));
      await put('zs_change', zs == null ? '' : _changeText(zs.change, zs.rate));
      await put('zs_flag', zs == null ? '' : ((zs.change ?? 0) >= 0 ? 'up' : 'down'));
      await put('ld_price', ld == null ? '--' : _fmt(ld.price));
      await put('ld_change', ld == null ? '' : _changeText(ld.change, null) + (ld.ratePct == null ? '' : '   ${_pctText(ld.ratePct)}'));
      await put('ld_flag', ld == null ? '' : ((ld.change ?? 0) >= 0 ? 'up' : 'down'));
      await put('updated',
          '更新 ${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}');
      await HomeWidget.updateWidget(
        name: 'GoldWidgetProvider',
        androidName: 'GoldWidgetProvider',
      );
    } catch (_) {}
  }

  Future<void> _checkAlerts(double p) async {
    if (_upOn && _upPrice != null && p >= _upPrice!) {
      _upOn = false; // 先关，避免重复触发
      await _prefs.setBool('up_on', false);
      await _notify(
        1001,
        '金价上涨提醒',
        '当前 ${_fmt(p)} 元/克，已涨到 ${_fmt(_upPrice!)} 以上',
      );
      FlutterForegroundTask.sendDataToMain(
          {'type': 'fired', 'which': 'up', 'price': p});
    }
    if (_downOn && _downPrice != null && p <= _downPrice!) {
      _downOn = false;
      await _prefs.setBool('down_on', false);
      await _notify(
        1002,
        '金价下跌提醒',
        '当前 ${_fmt(p)} 元/克，已跌到 ${_fmt(_downPrice!)} 以下',
      );
      FlutterForegroundTask.sendDataToMain(
          {'type': 'fired', 'which': 'down', 'price': p});
    }
  }

  Future<void> _notify(int id, String title, String body) async {
    try {
      await _notif.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: const fln.NotificationDetails(
          android: fln.AndroidNotificationDetails(
            // 渠道设置创建后无法修改，所以换了新的渠道 ID
            'gold_alert_v2',
            '金价提醒',
            channelDescription: '价格达到你设置的提醒值时通知',
            importance: fln.Importance.max,
            priority: fln.Priority.high,
            playSound: true,
            enableVibration: true,
            category: fln.AndroidNotificationCategory.alarm,
            audioAttributesUsage: fln.AudioAttributesUsage.alarm,
          ),
        ),
      );
    } catch (_) {}
  }

  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    final cmd = data['cmd'];
    if (cmd == 'reload') {
      _loadSettings();
    } else if (cmd == 'fast') {
      _fast = true;
    } else if (cmd == 'slow') {
      _fast = false;
    }
  }

  @override
  void onNotificationButtonPressed(String id) {
    if (id == 'stop') {
      FlutterForegroundTask.stopService();
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _ws?.close();
    _ws = null;
    await _saveHistory();
  }
}

// ===================================================================
// 界面
// ===================================================================
void main() {
  FlutterForegroundTask.initCommunicationPort();
  runApp(const GoldApp());
}

class GoldApp extends StatelessWidget {
  const GoldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '浙商金价',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFFD4A017),
        useMaterial3: true,
      ),
      home: const PricePage(),
    );
  }
}

class PricePage extends StatefulWidget {
  const PricePage({super.key});

  @override
  State<PricePage> createState() => _PricePageState();
}

class _PricePageState extends State<PricePage> with WidgetsBindingObserver {
  double? _price;
  double? _change;
  String? _rate;
  DateTime? _time;
  String? _raw;
  String? _error;

  double? _ldnPrice;
  double? _ldnChange;
  double? _ldnRate;
  double? _ldnHigh;
  double? _ldnLow;
  String? _ldnTime;
  DateTime? _ldnLocal;
  String? _ldnSource;
  String? _ldnRaw;
  String? _ldnError;
  int _bannerSeq = 0;

  // 三个胶囊卡片的顺序（可拖动调整，自动保存）
  List<String> _order = ['zs', 'ldn', 'sr', 'alert'];

  static const List<int> _srMinutes = [30, 60, 240, 720];
  static const List<String> _srNames = ['30分钟', '1小时', '4小时', '半天'];
  List<Map<String, dynamic>> _sr = [];
  int _srIdx = 1;

  bool _running = false;
  bool _notifOk = true;

  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();
  final TextEditingController _upCtl = TextEditingController();
  final TextEditingController _downCtl = TextEditingController();
  bool _upOn = false;
  bool _downOn = false;

  Timer? _syncTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    FlutterForegroundTask.addTaskDataCallback(_onData);
    _loadSettings();
    _loadOrder();
    _syncTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _syncRunning());
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FlutterForegroundTask.removeTaskDataCallback(_onData);
    _syncTimer?.cancel();
    _upCtl.dispose();
    _downCtl.dispose();
    super.dispose();
  }

  // 前台每秒刷新，切到后台降为每 5 秒（省电）
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_running) return;
    if (state == AppLifecycleState.resumed) {
      FlutterForegroundTask.sendDataToTask({'cmd': 'fast'});
      _loadSettings();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      FlutterForegroundTask.sendDataToTask({'cmd': 'slow'});
    }
  }

  // ---------- 服务控制 ----------
  Future<void> _bootstrap() async {
    var perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
      perm = await FlutterForegroundTask.checkNotificationPermission();
    }
    if (mounted) {
      setState(() => _notifOk = perm == NotificationPermission.granted);
    }

    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }

    _initService();
    await _startService();
  }

  void _initService() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'gold_monitor',
        channelName: '金价监控',
        channelDescription: '后台持续监控金价，用于价格提醒',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(1000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _startService() async {
    if (!await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.startService(
        serviceId: 256,
        notificationTitle: '浙商金价监控中',
        notificationText: '正在获取价格…',
        notificationButtons: [
          const NotificationButton(id: 'stop', text: '停止监控'),
        ],
        callback: startCallback,
      );
    }
    await _syncRunning();
    if (!_running && mounted) {
      setState(() => _error = '后台监控启动失败，请点右上角按钮重试');
    }
  }

  Future<void> _syncRunning() async {
    final r = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() => _running = r);
  }

  Future<void> _toggleService() async {
    if (_running) {
      await FlutterForegroundTask.stopService();
      await _syncRunning();
    } else {
      setState(() => _error = null);
      await _startService();
    }
  }

  // ---------- 接收后台数据 ----------
  void _onData(Object data) {
    if (data is! Map || !mounted) return;
    final type = data['type'];
    if (type == 'quote') {
      setState(() {
        _price = _toDouble(data['price']);
        _change = _toDouble(data['change']);
        _rate = data['rate']?.toString();
        _raw = data['raw']?.toString();
        _time = DateTime.now();
        _error = null;
      });
    } else if (type == 'error') {
      setState(() => _error = data['msg']?.toString());
    } else if (type == 'ldn') {
      setState(() {
        _ldnPrice = _toDouble(data['price']);
        _ldnChange = _toDouble(data['change']);
        _ldnRate = _toDouble(data['rate']);
        _ldnHigh = _toDouble(data['high']);
        _ldnLow = _toDouble(data['low']);
        _ldnTime = data['time']?.toString();
        _ldnLocal = DateTime.now();
        _ldnSource = data['source']?.toString();
        _ldnRaw = data['raw']?.toString();
        _ldnError = null;
      });
    } else if (type == 'sr') {
      try {
        final list = jsonDecode(data['json'].toString()) as List;
        setState(() => _sr =
            list.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      } catch (_) {}
    } else if (type == 'ldnError') {
      setState(() => _ldnError = data['msg']?.toString());
    } else if (type == 'fired') {
      final up = data['which'] == 'up';
      setState(() {
        if (up) {
          _upOn = false;
        } else {
          _downOn = false;
        }
      });
      final p = _toDouble(data['price']);
      _snack(
        '${up ? '涨到' : '跌到'}提醒已触发'
        '${p == null ? '' : '（当前 ${_fmt(p)}）'}，该提醒已自动关闭',
        sticky: true,
      );
    }
  }

  // ---------- 卡片顺序 ----------
  Future<void> _loadOrder() async {
    final saved = await _prefs.getString('card_order');
    final idx = await _prefs.getInt('sr_idx');
    if (!mounted) return;
    setState(() {
      if (idx != null && idx >= 0 && idx < _srMinutes.length) _srIdx = idx;
      if (saved != null) {
        const valid = ['zs', 'ldn', 'sr', 'alert'];
        final seen = <String>{};
        final list =
            saved.split(',').where((e) => valid.contains(e) && seen.add(e)).toList();
        // 旧版本保存的顺序里没有“支撑/阻力”：放到伦敦金后面
        if (!list.contains('sr')) {
          final i = list.indexOf('ldn');
          list.insert(i >= 0 ? i + 1 : list.length, 'sr');
        }
        for (final v in valid) {
          if (!list.contains(v)) list.add(v);
        }
        _order = list;
      }
    });
  }

  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _order.removeAt(oldIndex);
      _order.insert(newIndex, item);
    });
    _prefs.setString('card_order', _order.join(','));
  }

  // ---------- 提醒设置 ----------
  Future<void> _loadSettings() async {
    final upOn = await _prefs.getBool('up_on') ?? false;
    final downOn = await _prefs.getBool('down_on') ?? false;
    final up = await _prefs.getDouble('up_price');
    final down = await _prefs.getDouble('down_price');
    if (!mounted) return;
    setState(() {
      _upOn = upOn;
      _downOn = downOn;
      if (_upCtl.text.isEmpty && up != null) _upCtl.text = _fmt(up);
      if (_downCtl.text.isEmpty && down != null) _downCtl.text = _fmt(down);
    });
  }

  Future<void> _saveAlerts() async {
    await _prefs.setBool('up_on', _upOn);
    await _prefs.setBool('down_on', _downOn);
    final u = double.tryParse(_upCtl.text.trim());
    final d = double.tryParse(_downCtl.text.trim());
    if (u != null) await _prefs.setDouble('up_price', u);
    if (d != null) await _prefs.setDouble('down_price', d);
    FlutterForegroundTask.sendDataToTask({'cmd': 'reload'});
  }

  void _toggleUp(bool v) {
    if (v) {
      final u = double.tryParse(_upCtl.text.trim());
      if (u == null || u <= 0) {
        _snack('请先填写“涨到”的提醒价格');
        return;
      }
      if (_price != null && u <= _price!) {
        _snack('涨到的提醒价需要高于当前价 ${_fmt(_price!)}');
        return;
      }
    }
    setState(() => _upOn = v);
    _saveAlerts();
  }

  void _toggleDown(bool v) {
    if (v) {
      final d = double.tryParse(_downCtl.text.trim());
      if (d == null || d <= 0) {
        _snack('请先填写“跌到”的提醒价格');
        return;
      }
      if (_price != null && d >= _price!) {
        _snack('跌到的提醒价需要低于当前价 ${_fmt(_price!)}');
        return;
      }
    }
    setState(() => _downOn = v);
    _saveAlerts();
  }

  // 修改价格后自动关闭开关，避免输入过程中误触发
  void _onEditUp() {
    if (_upOn) {
      setState(() => _upOn = false);
      _saveAlerts();
    }
  }

  void _onEditDown() {
    if (_downOn) {
      setState(() => _downOn = false);
      _saveAlerts();
    }
  }

  // 应用内提示：显示在页面顶部；sticky 的需要手动点“知道了”关闭
  void _snack(String msg, {bool sticky = false}) {
    if (!mounted) return;
    final m = ScaffoldMessenger.of(context);
    final seq = ++_bannerSeq;
    m.hideCurrentMaterialBanner();
    m.showMaterialBanner(
      MaterialBanner(
        content: Text(msg),
        leading: Icon(
          sticky ? Icons.notifications_active : Icons.info_outline,
          color: Colors.orange.shade800,
        ),
        backgroundColor: Colors.amber.shade100,
        actions: [
          TextButton(
            onPressed: () => m.hideCurrentMaterialBanner(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    if (!sticky) {
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted && seq == _bannerSeq) m.hideCurrentMaterialBanner();
      });
    }
  }

  Future<void> _addWidget() async {
    try {
      await HomeWidget.requestPinWidget(
        name: 'GoldWidgetProvider',
        androidName: 'GoldWidgetProvider',
      );
      _snack('如果没有弹出添加窗口，请长按桌面空白处 → 小组件 → 浙商金价');
    } catch (_) {
      _snack('请长按桌面空白处 → 小组件 → 浙商金价，手动添加');
    }
  }

  void _showRaw() {
    var zs = _raw ?? '还没有收到数据';
    try {
      if (_raw != null) {
        zs = const JsonEncoder.withIndent('  ').convert(jsonDecode(_raw!));
      }
    } catch (_) {}
    final text = '【浙商接口】\n$zs\n\n【伦敦金接口（新浪 hf_XAU）】\n'
        '${_ldnRaw ?? '还没有收到数据'}';
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('接口原始数据'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  // ---------- 界面 ----------
  Widget _banner(String text, {String? actionText, VoidCallback? onAction}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(30),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
          const SizedBox(width: 8),
          Expanded(child: Text(text)),
          if (actionText != null)
            TextButton(onPressed: onAction, child: Text(actionText)),
        ],
      ),
    );
  }

  // 胶囊容器：顶部是标题和拖动手柄
  Widget _capsule({
    required Key key,
    required int index,
    required String title,
    required Widget child,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      key: key,
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(24, 10, 12, 22),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(36),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
                ),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Icon(Icons.drag_indicator, color: scheme.outline),
                ),
              ),
            ],
          ),
          child,
        ],
      ),
    );
  }

  // 涨跌小胶囊
  Widget _changePill(String text, Color color) {
    if (text.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text, style: TextStyle(fontSize: 16, color: color)),
    );
  }

  Widget _zsContent() {
    final up = (_change ?? 0) >= 0;
    final color = up ? Colors.red.shade700 : Colors.green.shade700;
    final t = _time;
    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_price == null && _error == null)
            const Padding(
              padding: EdgeInsets.all(12),
              child: CircularProgressIndicator(),
            ),
          if (_price != null) ...[
            Text(
              _fmt(_price!),
              style: TextStyle(
                fontSize: 56,
                height: 1.1,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            _changePill(_changeText(_change, _rate), color),
            if (t != null) ...[
              const SizedBox(height: 10),
              Text(
                '更新于 ${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          ],
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text('获取失败：$_error',
                style: TextStyle(color: Colors.orange.shade800)),
          ],
        ],
      ),
    );
  }

  Widget _londonContent() {
    final up = (_ldnChange ?? 0) >= 0;
    final color = up ? Colors.red.shade700 : Colors.green.shade700;
    final lt = _ldnLocal;
    final detail = [
      if (_ldnSource == 'ws') '京东实时推送',
      if (_ldnSource == 'sina') '备用行情（新浪，较慢）',
      if (lt != null)
        '更新于 ${_two(lt.hour)}:${_two(lt.minute)}:${_two(lt.second)}',
      if (_ldnHigh != null && _ldnLow != null)
        '最高 ${_fmt(_ldnHigh!)}  最低 ${_fmt(_ldnLow!)}',
      if (_ldnTime != null && _ldnTime!.isNotEmpty) '行情时间 $_ldnTime',
    ].join('   ');
    final changeText = [
      if (_ldnChange != null)
        '${_ldnChange! >= 0 ? '+' : ''}${_fmt(_ldnChange!)}',
      if (_ldnRate != null) _pctText(_ldnRate),
    ].join('   ');

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_ldnPrice == null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _ldnError != null ? '获取失败：$_ldnError' : '加载中…',
                style: TextStyle(
                  color:
                      _ldnError != null ? Colors.orange.shade800 : Colors.grey,
                ),
              ),
            )
          else ...[
            Text(
              _fmt(_ldnPrice!),
              style: TextStyle(
                fontSize: 44,
                height: 1.1,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 8),
            _changePill(changeText, color),
            if (detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(detail,
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ],
            if (_ldnError != null) ...[
              const SizedBox(height: 6),
              Text('更新失败：$_ldnError',
                  style: TextStyle(fontSize: 12, color: Colors.orange.shade800)),
            ],
          ],
        ],
      ),
    );
  }

  Widget _alertRow({
    required String label,
    required TextEditingController controller,
    required bool on,
    required ValueChanged<bool> onToggle,
    required VoidCallback onEdit,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: label,
                suffixText: '元/克',
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
              onChanged: (_) => onEdit(),
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: on, onChanged: onToggle),
        ],
      ),
    );
  }

  Widget _levelBlock(String label, double? level, double? strength, Color color) {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    if (level == null) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text('$label：现价已在区间边缘，这一侧暂无明显的位置',
            style: TextStyle(fontSize: 13, color: grey)),
      );
    }
    final cur = _price;
    final diff = cur == null ? null : level - cur;
    final pct = (cur == null || cur == 0 || diff == null) ? null : diff / cur * 100;
    final str = strength == null
        ? ''
        : (strength >= 0.8 ? '强' : (strength >= 0.5 ? '中' : '弱'));
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label, style: TextStyle(fontSize: 14, color: grey)),
              const SizedBox(width: 8),
              if (str.isNotEmpty) _changePill('强度 $str', color),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _fmt(level),
                style: TextStyle(
                    fontSize: 32,
                    height: 1.1,
                    fontWeight: FontWeight.bold,
                    color: color),
              ),
              const Spacer(),
              if (diff != null)
                Text(
                  '距现价 ${diff >= 0 ? '+' : ''}${_fmt(diff)}'
                  '${pct == null ? '' : '（${_pctText(pct)}）'}',
                  style: TextStyle(fontSize: 12, color: grey),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _srContent() {
    final grey = Theme.of(context).colorScheme.onSurfaceVariant;
    final d = _srIdx < _sr.length ? _sr[_srIdx] : null;
    final win = _srMinutes[_srIdx];
    final have = (d?['have'] as num?)?.toInt() ?? 0;

    final List<Widget> body;
    if (d == null || d['ok'] != true) {
      body = [
        Text(
          '数据积累中：已记录 $have 分钟，至少需要 3 分钟才能计算。\n'
          '价格历史只在 App 后台监控运行期间记录，要看“半天”的结果，需要先持续运行半天。',
          style: TextStyle(fontSize: 13, color: grey),
        ),
      ];
    } else if (d['flat'] == true) {
      body = [
        Text('这段时间价格几乎没有波动，没有可参考的支撑/阻力。',
            style: TextStyle(fontSize: 13, color: grey)),
      ];
    } else {
      final res = (d['res'] as num?)?.toDouble();
      final sup = (d['sup'] as num?)?.toDouble();
      final cur = _price;
      body = [
        _levelBlock('最强阻力位', res, (d['resStr'] as num?)?.toDouble(),
            Colors.red.shade700),
        _levelBlock('最强支撑位', sup, (d['supStr'] as num?)?.toDouble(),
            Colors.green.shade700),
        if (res != null && sup != null && cur != null && res > sup) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: ((cur - sup) / (res - sup)).clamp(0.0, 1.0),
              minHeight: 8,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '现价位于 ${_fmt(sup)} ~ ${_fmt(res)} 区间的 '
            '${(((cur - sup) / (res - sup)).clamp(0.0, 1.0) * 100).round()}% 位置',
            style: TextStyle(fontSize: 12, color: grey),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '区间最高 ${_fmt((d['hi'] as num).toDouble())}   '
          '最低 ${_fmt((d['lo'] as num).toDouble())}'
          '${have < win * 0.9 ? '\n已记录 $have 分钟，不足 $win 分钟，结果仅供参考' : ''}',
          style: TextStyle(fontSize: 12, color: grey),
        ),
      ];
    }

    return SizedBox(
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (var i = 0; i < _srNames.length; i++)
                ChoiceChip(
                  label: Text(_srNames[i]),
                  selected: _srIdx == i,
                  showCheckmark: false,
                  shape: const StadiumBorder(),
                  onSelected: (_) {
                    setState(() => _srIdx = i);
                    _prefs.setInt('sr_idx', i);
                  },
                ),
            ],
          ),
          ...body,
          const SizedBox(height: 10),
          Text(
            '按本机记录的浙商价格统计：价格停留的密集区 + 反复见顶/见底的位置。'
            '这是统计参考，不是预测，也不构成投资建议。',
            style: TextStyle(fontSize: 11, color: grey),
          ),
        ],
      ),
    );
  }

  Widget _alertContent() {
    return Column(
      children: [
        _alertRow(
          label: '涨到此价提醒',
          controller: _upCtl,
          on: _upOn,
          onToggle: _toggleUp,
          onEdit: _onEditUp,
        ),
        _alertRow(
          label: '跌到此价提醒',
          controller: _downCtl,
          on: _downOn,
          onToggle: _toggleDown,
          onEdit: _onEditDown,
        ),
      ],
    );
  }

  Widget _buildCard(String id, int index) {
    switch (id) {
      case 'zs':
        return _capsule(
          key: const ValueKey('zs'),
          index: index,
          title: '浙商积存金 · 元/克',
          child: _zsContent(),
        );
      case 'ldn':
        return _capsule(
          key: const ValueKey('ldn'),
          index: index,
          title: '伦敦金 · 美元/盎司',
          child: _londonContent(),
        );
      case 'sr':
        return _capsule(
          key: const ValueKey('sr'),
          index: index,
          title: '支撑 / 阻力 · 浙商 · 元/克',
          child: _srContent(),
        );
      default:
        return _capsule(
          key: const ValueKey('alert'),
          index: index,
          title: '价格提醒',
          child: _alertContent(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('金价'),
        actions: [
          IconButton(
            icon: const Icon(Icons.widgets_outlined),
            tooltip: '添加桌面小组件',
            onPressed: _addWidget,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: '接口原始数据',
            onPressed: _showRaw,
          ),
          IconButton(
            icon: Icon(_running
                ? Icons.stop_circle_outlined
                : Icons.play_circle_outline),
            tooltip: _running ? '停止后台监控' : '开启后台监控',
            onPressed: _toggleService,
          ),
        ],
      ),
      body: ReorderableListView(
        padding: const EdgeInsets.all(16),
        buildDefaultDragHandles: false,
        onReorder: _onReorder,
        proxyDecorator: (child, index, animation) => Material(
          color: Colors.transparent,
          elevation: 8,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(36),
          child: child,
        ),
        header: Column(
          children: [
            if (!_notifOk)
              _banner('通知权限未开启，提醒无法弹出。请在系统设置里允许本应用的通知。'),
            if (!_running)
              _banner('后台监控已停止，价格不再更新，提醒也不会触发。',
                  actionText: '开启', onAction: _toggleService),
          ],
        ),
        footer: const Padding(
          padding: EdgeInsets.only(top: 16, bottom: 8),
          child: Center(
            child: Text(
              '按住卡片右上角的 ⋮⋮ 图标上下拖动，可调整顺序\n'
              'App 在前台时浙商、伦敦金都每秒刷新，退到后台会放慢\n'
              '提醒触发一次后会自动关闭，需要时重新打开开关\n'
              '数据来自第三方接口，仅供参考，以银行实际成交价为准',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ),
        children: [
          for (var i = 0; i < _order.length; i++) _buildCard(_order[i], i),
        ],
      ),
    );
  }
}
