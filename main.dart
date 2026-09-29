import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

// 数据来源：京东金融浙商银行积存金（非官方公开接口，可能随时变动）
const String _sku = '1961543816';
const String _apiUrl =
    'https://api.jdjygold.com/gw2/generic/jrm/h5/m/stdLatestPrice';
const Duration _refreshEvery = Duration(seconds: 5);

const Map<String, String> _headers = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/120.0 Mobile Safari/537.36',
  'Accept': 'application/json',
};

class GoldQuote {
  final double price; // 元/克
  final double? change; // 涨跌额
  final String? rate; // 涨跌幅（原样显示）
  final DateTime time;

  GoldQuote(this.price, this.change, this.rate, this.time);
}

double? _toDouble(dynamic v) => v == null ? null : double.tryParse(v.toString());

Map<String, dynamic>? _extractDatas(http.Response res) {
  if (res.statusCode != 200) return null;
  try {
    final body = jsonDecode(utf8.decode(res.bodyBytes));
    final datas = body['resultData']?['datas'];
    if (datas is Map<String, dynamic> && datas['price'] != null) return datas;
  } catch (_) {}
  return null;
}

Future<GoldQuote> fetchQuote() async {
  const timeout = Duration(seconds: 8);

  // 先用 GET，失败再退回 POST
  var res = await http
      .get(Uri.parse('$_apiUrl?productSku=$_sku'), headers: _headers)
      .timeout(timeout);
  var datas = _extractDatas(res);

  if (datas == null) {
    res = await http
        .post(Uri.parse(_apiUrl), headers: _headers, body: {'productSku': _sku})
        .timeout(timeout);
    datas = _extractDatas(res);
  }
  if (datas == null) {
    throw Exception('接口返回格式异常（HTTP ${res.statusCode}）');
  }

  final price = _toDouble(datas['price']);
  if (price == null) throw Exception('价格字段无法解析');

  final ts = _toDouble(datas['time']);
  final time = (ts != null && ts > 1e12)
      ? DateTime.fromMillisecondsSinceEpoch(ts.toInt())
      : DateTime.now();

  return GoldQuote(
    price,
    _toDouble(datas['upAndDownAmt']),
    datas['upAndDownRate']?.toString(),
    time,
  );
}

void main() => runApp(const GoldApp());

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
  GoldQuote? _quote;
  String? _error;
  bool _loading = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _startTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  // 切到后台停止轮询，回到前台立即刷新
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
      _startTimer();
    } else {
      _timer?.cancel();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(_refreshEvery, (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final q = await fetchQuote();
      if (!mounted) return;
      setState(() {
        _quote = q;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    // 国内习惯：红涨绿跌
    final up = (q?.change ?? 0) >= 0;
    final color = up ? Colors.red.shade700 : Colors.green.shade700;

    return Scaffold(
      appBar: AppBar(
        title: const Text('浙商积存金'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 40),
            if (q == null && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (q != null) ...[
              const Center(
                child: Text('实时金价（元/克）', style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  q.price.toStringAsFixed(2),
                  style: TextStyle(
                    fontSize: 64,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  [
                    if (q.change != null)
                      '${q.change! >= 0 ? '+' : ''}${q.change!.toStringAsFixed(2)}',
                    if (q.rate != null) q.rate!,
                  ].join('   '),
                  style: TextStyle(fontSize: 22, color: color),
                ),
              ),
              const SizedBox(height: 24),
              Center(
                child: Text(
                  '更新于 ${_two(q.time.hour)}:${_two(q.time.minute)}:${_two(q.time.second)}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 24),
              Center(
                child: Text(
                  '获取失败：$_error',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.orange.shade800),
                ),
              ),
            ],
            const SizedBox(height: 48),
            const Center(
              child: Text(
                '每 5 秒自动刷新，下拉可手动刷新\n数据来自第三方接口，仅供参考，以银行实际成交价为准',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
