import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart'
    as fln;
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

double? _toDouble(dynamic v) =>
    v == null ? null : double.tryParse(v.toString());
String _two(int n) => n.toString().padLeft(2, '0');
String _dateKey(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';
String _fmt(double v) => v.toStringAsFixed(2);

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
          ? await http
              .post(Uri.parse(_apiUrl),
                  headers: _headers, body: {'productSku': _sku})
              .timeout(_timeout)
          : await http
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
// 后台服务：每秒取价、记录今日最高/最低、触发提醒
// ===================================================================
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(MonitorHandler());
}

class MonitorHandler extends TaskHandler {
  final fln.FlutterLocalNotificationsPlugin _notif =
      fln.FlutterLocalNotificationsPlugin();
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  bool _busy = false;
  bool _fast = true; // App 在前台：每秒；在后台：每 5 秒
  int _tick = 0;
  DateTime _lastNotifUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  bool _upOn = false;
  bool _downOn = false;
  double? _upPrice;
  double? _downPrice;

  String? _hlDate;
  double? _high;
  double? _low;

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
    _hlDate = await _prefs.getString('hl_date');
    _high = await _prefs.getDouble('hl_high');
    _low = await _prefs.getDouble('hl_low');
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
    if (_busy) return;
    if (!_fast && _tick % 5 != 0) return;
    _poll();
  }

  Future<void> _poll() async {
    _busy = true;
    try {
      final q = await fetchQuote();
      _updateHighLow(q.price);
      await _checkAlerts(q.price);

      FlutterForegroundTask.sendDataToMain({
        'type': 'quote',
        'price': q.price,
        'change': q.change,
        'rate': q.rate,
        'high': _high,
        'low': _low,
        'raw': jsonEncode(q.raw),
      });

      final now = DateTime.now();
      if (now.difference(_lastNotifUpdate).inSeconds >= 3) {
        _lastNotifUpdate = now;
        FlutterForegroundTask.updateService(
          notificationTitle: '浙商金价 ${_fmt(q.price)} 元/克',
          notificationText: '今日 最高 ${_fmt(_high!)}  最低 ${_fmt(_low!)}',
        );
      }
    } catch (e) {
      FlutterForegroundTask.sendDataToMain(
          {'type': 'error', 'msg': _cleanError(e)});
    } finally {
      _busy = false;
    }
  }

  // 今日最高/最低：按自然日统计，仅包含 App 监控期间看到的价格
  void _updateHighLow(double p) {
    final today = _dateKey(DateTime.now());
    var changed = false;
    if (_hlDate != today || _high == null || _low == null) {
      _hlDate = today;
      _high = p;
      _low = p;
      changed = true;
    } else {
      if (p > _high!) {
        _high = p;
        changed = true;
      }
      if (p < _low!) {
        _low = p;
        changed = true;
      }
    }
    if (changed) _saveHighLow();
  }

  Future<void> _saveHighLow() async {
    try {
      await _prefs.setString('hl_date', _hlDate!);
      await _prefs.setDouble('hl_high', _high!);
      await _prefs.setDouble('hl_low', _low!);
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
            'gold_alert',
            '金价提醒',
            channelDescription: '价格达到你设置的提醒值时通知',
            importance: fln.Importance.max,
            priority: fln.Priority.high,
            playSound: true,
            enableVibration: true,
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
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
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
  double? _high;
  double? _low;
  DateTime? _time;
  String? _raw;
  String? _error;

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
        _high = _toDouble(data['high']);
        _low = _toDouble(data['low']);
        _raw = data['raw']?.toString();
        _time = DateTime.now();
        _error = null;
      });
    } else if (type == 'error') {
      setState(() => _error = data['msg']?.toString());
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
      _snack('${up ? '涨到' : '跌到'}提醒已触发'
          '${p == null ? '' : '（当前 ${_fmt(p)}）'}，该提醒已自动关闭');
    }
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

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  void _showRaw() {
    var text = _raw ?? '还没有收到数据';
    try {
      if (_raw != null) {
        text = const JsonEncoder.withIndent('  ').convert(jsonDecode(_raw!));
      }
    } catch (_) {}
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
    return Card(
      color: Colors.orange.shade50,
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
            if (actionText != null)
              TextButton(onPressed: onAction, child: Text(actionText)),
          ],
        ),
      ),
    );
  }

  Widget _statCard(String label, double? value, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            children: [
              Text(label, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 6),
              Text(
                value == null ? '--' : _fmt(value),
                style: TextStyle(
                    fontSize: 24, fontWeight: FontWeight.bold, color: color),
              ),
            ],
          ),
        ),
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
      padding: const EdgeInsets.only(top: 12),
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
                border: const OutlineInputBorder(),
                isDense: true,
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

  String _two2(int n) => _two(n);

  @override
  Widget build(BuildContext context) {
    final up = (_change ?? 0) >= 0;
    final color = up ? Colors.red.shade700 : Colors.green.shade700;
    final t = _time;

    return Scaffold(
      appBar: AppBar(
        title: const Text('浙商积存金'),
        actions: [
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
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_notifOk)
            _banner('通知权限未开启，提醒无法弹出。请在系统设置里允许本应用的通知。'),
          if (!_running)
            _banner('后台监控已停止，价格不再更新，提醒也不会触发。',
                actionText: '开启', onAction: _toggleService),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: Column(
                children: [
                  const Text('实时金价（元/克）', style: TextStyle(fontSize: 16)),
                  const SizedBox(height: 12),
                  if (_price == null && _error == null)
                    const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(),
                    ),
                  if (_price != null) ...[
                    Text(
                      _fmt(_price!),
                      style: TextStyle(
                        fontSize: 64,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        if (_change != null)
                          '${_change! >= 0 ? '+' : ''}${_fmt(_change!)}',
                        if (_rate != null) _rate!,
                      ].join('   '),
                      style: TextStyle(fontSize: 20, color: color),
                    ),
                    if (t != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '更新于 ${_two2(t.hour)}:${_two2(t.minute)}:${_two2(t.second)}',
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      '获取失败：$_error',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.orange.shade800),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Row(
            children: [
              _statCard('今日最高', _high, Colors.red.shade700),
              _statCard('今日最低', _low, Colors.green.shade700),
            ],
          ),
          const SizedBox(height: 4),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('价格提醒',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
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
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Center(
            child: Text(
              'App 在前台每秒刷新，退到后台每 5 秒刷新\n'
              '提醒触发一次后会自动关闭，需要时重新打开开关\n'
              '今日最高/最低按自然日统计，仅包含 App 监控期间的价格\n'
              '数据来自第三方接口，仅供参考，以银行实际成交价为准',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
