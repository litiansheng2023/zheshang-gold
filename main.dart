import 'dart:async';
import 'dart:convert';

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
// 伦敦金（现货黄金，美元/盎司）：新浪财经行情 hf_XAU（非官方接口）
// 字段：0 最新价 … 4 最高 5 最低 6 行情时间 7 昨收 8 开盘
// ===================================================================
const String _ldnUrl = 'https://hq.sinajs.cn/list=hf_XAU';

class LondonQuote {
  final double price;
  final double? change; // 涨跌额（相对昨收）
  final double? ratePct; // 涨跌幅 %
  final double? high;
  final double? low;
  final String? quoteTime;
  final String raw;

  LondonQuote(this.price, this.change, this.ratePct, this.high, this.low,
      this.quoteTime, this.raw);
}

Future<LondonQuote> fetchLondon() async {
  final http.Response res = await http.get(
    Uri.parse(_ldnUrl),
    headers: {
      'Referer': 'https://finance.sina.com.cn',
      'User-Agent': _headers['User-Agent']!,
    },
  ).timeout(_timeout);
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
      price, change, ratePct, high, low, f[6].trim(), text.trim());
}

// ===================================================================
// 后台服务：每秒取价、触发提醒
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
  bool _busyLdn = false;
  DateTime _ldnBackoffUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _fast = true; // App 在前台：每秒；在后台：每 5 秒
  int _tick = 0;
  DateTime _lastPublish = DateTime.fromMillisecondsSinceEpoch(0);

  GoldQuote? _zs;
  LondonQuote? _ldn;

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
    // 伦敦金：前台每秒，后台每 15 秒；失败后退避 5 秒再试
    if (!_busyLdn &&
        DateTime.now().isAfter(_ldnBackoffUntil) &&
        (_fast || (_tick - 1) % 15 == 0)) {
      _pollLondon();
    }
  }

  Future<void> _poll() async {
    _busy = true;
    try {
      final q = await fetchQuote();
      _zs = q;
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
      final q = await fetchLondon();
      _ldn = q;
      FlutterForegroundTask.sendDataToMain({
        'type': 'ldn',
        'price': q.price,
        'change': q.change,
        'rate': q.ratePct,
        'high': q.high,
        'low': q.low,
        'time': q.quoteTime,
        'raw': q.raw,
      });
      _publish();
    } catch (e) {
      _ldnBackoffUntil = DateTime.now().add(const Duration(seconds: 5));
      FlutterForegroundTask.sendDataToMain(
          {'type': 'ldnError', 'msg': _cleanError(e)});
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
  DateTime? _time;
  String? _raw;
  String? _error;

  double? _ldnPrice;
  double? _ldnChange;
  double? _ldnRate;
  double? _ldnHigh;
  double? _ldnLow;
  String? _ldnTime;
  String? _ldnRaw;
  String? _ldnError;
  int _bannerSeq = 0;

  // 三个胶囊卡片的顺序（可拖动调整，自动保存）
  List<String> _order = ['zs', 'ldn', 'alert'];

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
        _ldnRaw = data['raw']?.toString();
        _ldnError = null;
      });
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
    if (saved == null) return;
    final list = saved.split(',');
    const valid = {'zs', 'ldn', 'alert'};
    if (list.length == 3 &&
        list.toSet().length == 3 &&
        list.every(valid.contains) &&
        mounted) {
      setState(() => _order = list);
    }
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
    final detail = [
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
