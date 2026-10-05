import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(MaterialApp(
    title: 'WiFi Manager',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
    home: const Login()));

class Dev {
  String name, ip, mac;
  Dev(this.name, this.ip, this.mac);
}

// ---------- Huawei HG8546M ----------
class HRouter {
  final String base;
  String cookie = 'Cookie=body:Language:english:id=-1;path=/';
  HRouter(String ip) : base = 'http://$ip';
  Map<String, String> get _h =>
      {'Referer': '$base/', 'Cookie': cookie, 'Content-Type': 'application/x-www-form-urlencoded'};
  Future<http.Response> _post(String p, Map<String, String> b) =>
      http.post(Uri.parse(base + p), headers: _h, body: b)
          .timeout(const Duration(seconds: 8));
  Future<String> _get(String p) async => (await http
          .get(Uri.parse(base + p), headers: _h)
          .timeout(const Duration(seconds: 8)))
      .body;
  Future<String> _token() async =>
      (await _post('/asp/GetRandCount.asp', {}))
          .body
          .replaceAll(RegExp(r'[^0-9A-Za-z]'), '');

  Future<bool> login(String u, String p) async {
    final t = await _token();
    final r = await _post('/login.cgi', {
      'UserName': u,
      'PassWord': base64.encode(utf8.encode(p)),
      'Language': 'english',
      'x.X_HW_Token': t
    });
    final sc = r.headers['set-cookie'] ?? '';
    if (sc.contains('sid=')) {
      cookie = sc.split(';').first;
      return true;
    }
    return false;
  }

  String lastRaw = '';
  String _dec(String s) => s.replaceAllMapped(RegExp(r'\\x([0-9a-fA-F]{2})'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)));

  Future<List<Dev>> devices() async {
    final paths = [
      '/html/bbsp/common/GetLanUserDevInfo.asp',
      '/html/bbsp/common/GetLanUserInfo.asp',
      '/html/bbsp/userdevinfo/userdevinfo.asp'
    ];
    final out = <Dev>[];
    lastRaw = '';
    final ipRe = RegExp(r'^\d+\.\d+\.\d+\.\d+$');
    final macRe = RegExp(r'^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$');
    for (final path in paths) {
      String b;
      try {
        final r = await http.get(Uri.parse(base + path), headers: _h).timeout(const Duration(seconds: 8));
        b = _dec(r.body);
        lastRaw += '=== $path  status ${r.statusCode}  len ${b.length}\n${b.length > 1500 ? b.substring(0, 1500) : b}\n\n';
      } catch (e) {
        lastRaw += '=== $path  ERROR $e\n\n';
        continue;
      }
      for (final m in RegExp(r'USERDevice\s*\(([^)]*)\)').allMatches(b)) {
        final f = RegExp(r"""["']([^"']*)["']""")
            .allMatches(m.group(1)!)
            .map((x) => x.group(1)!)
            .toList();
        final mac = f.firstWhere(macRe.hasMatch, orElse: () => '');
        if (mac.isEmpty) continue;
        final ip = f.firstWhere(ipRe.hasMatch, orElse: () => '');
        final name = f.length > 9 && f[9].isNotEmpty ? f[9] : 'Unknown';
        out.add(Dev(name, ip, mac.toUpperCase().replaceAll('-', ':')));
      }
      if (out.isNotEmpty) break;
    }
    return out;
  }

  Future<bool> _listed(String mac) async =>
      (await _get('/html/bbsp/macfilter/macfilter.asp'))
          .toUpperCase()
          .contains(mac.toUpperCase());

  String blockLog = '';
  Future<String> _filterLines() async {
    final p = await _get('/html/bbsp/macfilter/macfilter.asp');
    final ls = p
        .split('\n')
        .where((l) => RegExp(r'macfilter|Mode|Enable', caseSensitive: false).hasMatch(l))
        .join('\n');
    return ls.length > 2500 ? ls.substring(0, 2500) : ls;
  }

  Future<bool> block(String mac) async {
    blockLog = '--- BEFORE\n${await _filterLines()}\n';
    for (final x in [
      'InternetGatewayDevice.X_HW_Security.MacFilter',
      'InternetGatewayDevice.X_HW_Security.MacFilter.%7Bi%7D'
    ]) {
      final t = await _token();
      final r = await _post(
          '/html/bbsp/macfilter/add.cgi?x=$x&RequestFile=html/bbsp/macfilter/macfilter.asp',
          {'x.SourceMACAddress': mac, 'x.X_HW_Token': t});
      blockLog += '--- ADD $x status ${r.statusCode}\n${r.body.length > 300 ? r.body.substring(0, 300) : r.body}\n';
      if (await _listed(mac)) return true;
    }
    blockLog += '--- AFTER\n${await _filterLines()}\n\n';
    return false;
  }

  Future<bool> unblock(String mac) async {
    final page = await _get('/html/bbsp/macfilter/macfilter.asp');
    final i = page.toUpperCase().indexOf(mac.toUpperCase());
    if (i < 0) return true; // already not in router list
    final before = page.substring(i > 400 ? i - 400 : 0, i);
    final all = RegExp(r'InternetGatewayDevice\.X_HW_Security\.MacFilter\.\d+').allMatches(before);
    if (all.isEmpty) return false;
    final d = all.last.group(0);
    final t = await _token();
    await _post(
        '/html/bbsp/macfilter/del.cgi?x=$d&RequestFile=html/bbsp/macfilter/macfilter.asp',
        {'x.X_HW_Token': t});
    return !(await _listed(mac));
  }
}

// ---------- Login ----------
class Login extends StatefulWidget {
  const Login({super.key});
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  final ip = TextEditingController(text: '192.168.100.1');
  final user = TextEditingController();
  final pass = TextEditingController();
  bool busy = false;
  String err = '';

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final p = await SharedPreferences.getInstance();
    user.text = p.getString('user') ?? '';
    try {
      final g = await NetworkInfo().getWifiGatewayIP();
      if (g != null && g.isNotEmpty) ip.text = g;
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _go() async {
    setState(() {
      busy = true;
      err = '';
    });
    try {
      final r = HRouter(ip.text.trim());
      if (await r.login(user.text.trim(), pass.text)) {
        (await SharedPreferences.getInstance()).setString('user', user.text.trim());
        if (!mounted) return;
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => Home(r)));
        return;
      }
      err = 'Login fail: username/password check karein';
    } catch (e) {
      err = 'Router tak nahi pohnch saka (WiFi connected hai?): $e';
    }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: const Text('Router Login')),
        body: ListView(padding: const EdgeInsets.all(20), children: [
          TextField(controller: ip, decoration: const InputDecoration(labelText: 'Router IP')),
          TextField(controller: user, decoration: const InputDecoration(labelText: 'Username')),
          TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 20),
          FilledButton(onPressed: busy ? null : _go, child: Text(busy ? '...' : 'Login')),
          if (err.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(err, style: const TextStyle(color: Colors.red))),
        ]),
      );
}

// ---------- Home ----------
class Home extends StatefulWidget {
  final HRouter r;
  const Home(this.r, {super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  List<Dev> devs = [];
  Map<String, String> blocked = {}; // mac -> name
  Map<String, dynamic> hist = {}; // mac -> {name, days:[]}
  Map<String, String> names = {}; // mac -> custom name
  late SharedPreferences p;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    p = await SharedPreferences.getInstance();
    blocked = Map<String, String>.from(jsonDecode(p.getString('blocked') ?? '{}'));
    hist = Map<String, dynamic>.from(jsonDecode(p.getString('hist') ?? '{}'));
    names = Map<String, String>.from(jsonDecode(p.getString('names') ?? '{}'));
    await _refresh();
  }

  void _msg(String s) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));

  Future<void> _refresh() async {
    try {
      devs = await widget.r.devices();
      final today = DateTime.now().toIso8601String().substring(0, 10);
      for (final d in devs) {
        final h = hist.putIfAbsent(d.mac, () => {'name': d.name, 'days': <dynamic>[]});
        h['name'] = d.name;
        if (!(h['days'] as List).contains(today)) (h['days'] as List).add(today);
      }
      await p.setString('hist', jsonEncode(hist));
    } catch (e) {
      _msg('Refresh error: $e');
    }
    if (mounted) setState(() {});
  }

  String _nm(String mac, String fallback) => names[mac] ?? fallback;

  Future<void> _rename(String mac, String current, String routerName) async {
    final c = TextEditingController(text: current);
    final v = await showDialog<String>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Naam badlein'),
              content: TextField(controller: c, autofocus: true, decoration: InputDecoration(hintText: routerName, helperText: 'Khali chorein to asli naam wapas aa jayega')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(context, c.text.trim()), child: const Text('Save')),
              ],
            ));
    if (v == null) return;
    v.isEmpty ? names.remove(mac) : names[mac] = v;
    await p.setString('names', jsonEncode(names));
    if (mounted) setState(() {});
  }

  Future<void> _toggle(String mac, String name, bool block) async {
    try {
      final ok = block ? await widget.r.block(mac) : await widget.r.unblock(mac);
      if (ok) {
        block ? blocked[mac] = name : blocked.remove(mac);
        await p.setString('blocked', jsonEncode(blocked));
        _msg(block ? '$name block ho gaya' : '$name unblock ho gaya');
      } else {
        _msg('Router ne change accept nahi kiya');
      }
    } catch (e) {
      _msg('Error: $e');
    }
    await _refresh();
  }

  Widget _devices() => RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(children: [
          for (final d in devs)
            ListTile(
              title: Text(_nm(d.mac, d.name)),
              subtitle: Text('${d.ip}\n${d.mac}'),
              isThreeLine: true,
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () => _rename(d.mac, _nm(d.mac, d.name), d.name)),
                Switch(
                    value: blocked.containsKey(d.mac),
                    onChanged: (v) => _toggle(d.mac, _nm(d.mac, d.name), v)),
              ]),
            ),
        ]),
      );

  Widget _blockList() => ListView(children: [
        if (blocked.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Koi blocked device nahi')),
        for (final e in blocked.entries)
          ListTile(
            title: Text(_nm(e.key, e.value)),
            subtitle: Text(e.key),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () => _rename(e.key, _nm(e.key, e.value), e.value)),
              Switch(value: true, onChanged: (_) => _toggle(e.key, _nm(e.key, e.value), false)),
            ]),
          ),
      ]);

  Widget _report() {
    final from = DateTime.now().subtract(const Duration(days: 7)).toIso8601String().substring(0, 10);
    final rows = hist.entries.map((e) {
      final days = (e.value['days'] as List).where((d) => d.compareTo(from) >= 0).toList()..sort();
      return [_nm(e.key, e.value['name']), e.key, days];
    }).where((r) => (r[2] as List).isNotEmpty).toList()
      ..sort((a, b) => (b[2] as List).length.compareTo((a[2] as List).length));
    return ListView(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('Pichle 7 din: kaun kitne din connected dikha')),
      for (final r in rows)
        ListTile(
          title: Text('${r[0]}'),
          subtitle: Text('${r[1]}\nLast seen: ${(r[2] as List).last}'),
          isThreeLine: true,
          trailing: Text('${(r[2] as List).length}/7 din'),
        ),
    ]);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(['Devices (${devs.length})', 'Block List', 'Weekly Report'][tab]), actions: [
          IconButton(icon: const Icon(Icons.bug_report), onPressed: () => showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Debug (copy karke bhejein)'), content: SingleChildScrollView(child: SelectableText(widget.r.blockLog + widget.r.lastRaw))))),
          IconButton(icon: const Icon(Icons.refresh), onPressed: _refresh)
        ]),
        body: [_devices(), _blockList(), _report()][tab],
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.devices), label: 'Devices'),
            NavigationDestination(icon: Icon(Icons.block), label: 'Blocked'),
            NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Report'),
          ],
        ),
      );
}