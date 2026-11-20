import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences prefs;
String g(String k, String d) => prefs.getString(k) ?? d;

// FIX 1: defaults updated to models that currently exist (Groq retired llama-3.3-70b-versatile on 16 Aug 2026).
String defModel(String p) =>
    p == 'gemini' ? 'gemini-3.8-flash' : p == 'groq' ? 'openai/gpt-oss-120b' : 'openrouter/free';

// FIX 2: a retired model name saved earlier is replaced by the default automatically.
const kRetired = {'llama-3.3-70b-versatile', 'llama-3.1-8b-instant'};
String modelFor(String p) {
  final m = g('model_$p', '');
  return (m.isEmpty || kRetired.contains(m)) ? defModel(p) : m;
}

const kStr = {
  'bn': {'new': 'নতুন চ্যাট', 'settings': 'সেটিংস', 'hint': 'মেসেজ লিখুন...', 'nokey': 'আগে সেটিংসে API Key দিন', 'save': 'সংরক্ষণ', 'lang': 'ভাষা', 'provider': 'প্রোভাইডার', 'model': 'মডেল', 'key': 'API Key', 'backup': 'অন্য প্রোভাইডারের key দিলে সেগুলো স্বয়ংক্রিয় ব্যাকআপ হবে'},
  'en': {'new': 'New chat', 'settings': 'Settings', 'hint': 'Type a message...', 'nokey': 'Add your API key in Settings first', 'save': 'Save', 'lang': 'Language', 'provider': 'Provider', 'model': 'Model', 'key': 'API Key', 'backup': 'Providers with a saved key are used as automatic backup'},
};
Map<String, String> langMap() => kStr[g('lang', 'bn')] ?? kStr['bn']!;
String t(String k) => langMap()[k] ?? kStr['bn']![k]!;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'JamalsGPT',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF0B0B10),
            colorSchemeSeed: const Color(0xFF7C5CFF),
            useMaterial3: true),
        home: const Chat(),
      );
}

const kProviders = ['gemini', 'groq', 'openrouter'];
const kNames = {'gemini': 'Google Gemini', 'groq': 'Groq', 'openrouter': 'OpenRouter'};
const kUrls = {
  'groq': 'https://api.groq.com/openai/v1/chat/completions',
  'openrouter': 'https://openrouter.ai/api/v1/chat/completions',
};

class HttpErr implements Exception {
  final int code;
  final String body;
  HttpErr(this.code, this.body);
  bool get retry => code == 429 || code >= 500;
  @override
  String toString() => 'HTTP $code: ${body.length > 200 ? '${body.substring(0, 200)}...' : body}';
}

// FIX 3: the '⚡ provider' marker line is removed from the history, but the reply text is KEPT
// (before, the whole reply was dropped from the conversation memory).
String cleanText(String s) {
  if (s.startsWith('⚡ ')) {
    final i = s.indexOf('\n');
    return i < 0 ? '' : s.substring(i + 1);
  }
  return s;
}

List<Map<String, String>> buildHistory(List<Map> msgs) {
  final out = <Map<String, String>>[];
  for (final m in msgs) {
    final txt = cleanText(m['t'] as String);
    if (txt.isEmpty || txt.startsWith('⚠️')) continue;
    out.add({'r': m['r'] as String, 't': txt});
  }
  return out;
}

Stream<String> askOne(String p, List<Map> msgs) async* {
  final key = g('key_$p', '');
  final model = modelFor(p);
  final isG = p == 'gemini';
  final h = buildHistory(msgs);
  final req = http.Request(
      'POST',
      Uri.parse(isG
          ? 'https://generativelanguage.googleapis.com/v1beta/models/$model:streamGenerateContent?alt=sse'
          : kUrls[p]!));
  req.headers.addAll({
    'Content-Type': 'application/json',
    if (p == 'openrouter') 'HTTP-Referer': 'https://jamalsgpt.local',
    if (p == 'openrouter') 'X-Title': 'JamalsGPT',
    if (isG) 'x-goog-api-key': key else 'Authorization': 'Bearer $key',
  });
  req.body = jsonEncode(isG
      ? {
          'contents': [
            for (final m in h)
              {
                'role': m['r'] == 'user' ? 'user' : 'model',
                'parts': [{'text': m['t']}]
              }
          ]
        }
      : {
          'model': model,
          'stream': true,
          'messages': [for (final m in h) {'role': m['r'], 'content': m['t']}]
        });
  final client = http.Client();
  try {
    final res = await client.send(req).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) {
      final b = await res.stream.bytesToString();
      throw HttpErr(res.statusCode, b);
    }
    await for (final line in res.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(const Duration(minutes: 3), onTimeout: (sink) {
      sink.addError(TimeoutException('Stream stalled'));
      sink.close();
    })) {
      if (!line.startsWith('data:')) continue;
      final d = line.substring(5).trim();
      if (d.isEmpty || d == '[DONE]') continue;
      try {
        final j = jsonDecode(d);
        // FIX 4: Gemini may send several parts in one chunk; join all of them.
        final s = isG
            ? (j['candidates'][0]['content']['parts'] as List).map((x) => (x['text'] ?? '').toString()).join()
            : j['choices'][0]['delta']['content'];
        if (s is String && s.isNotEmpty) yield s;
      } catch (_) {}
    }
  } finally {
    client.close();
  }
}

// Tries the selected provider first (2 attempts), then every other provider that has a key.
Stream<String> ask(List<Map> msgs) async* {
  final sel = g('provider', 'gemini');
  final order = [sel, ...kProviders.where((p) => p != sel)];
  Object? lastErr;
  var used = 0;
  for (final p in order) {
    if (g('key_$p', '').isEmpty) continue;
    used++;
    for (var a = 0; a < 2; a++) {
      var started = false;
      try {
        await for (final s in askOne(p, msgs)) {
          if (!started) {
            started = true;
            if (p != sel) yield '⚡ ${kNames[p]}\n';
          }
          yield s;
        }
        return;
      } catch (e) {
        lastErr = e;
        if (started) rethrow;
        if (e is HttpErr && !e.retry) break;
        if (a == 0) await Future.delayed(const Duration(seconds: 2)); // FIX 5: no useless wait after the last try
      }
    }
  }
  if (used == 0) throw Exception(t('nokey'));
  throw lastErr!;
}

Map<String, dynamic> newChat() => {'title': t('new'), 'm': <dynamic>[]};

class Chat extends StatefulWidget {
  const Chat({super.key});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  late List<Map<String, dynamic>> chats;
  int cur = 0;
  bool busy = false;
  final ctrl = TextEditingController();
  final sc = ScrollController();

  @override
  void initState() {
    super.initState();
    try {
      chats = (jsonDecode(g('chats', '[]')) as List).map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) {
      chats = [];
    }
    if (chats.isEmpty) chats.add(newChat());
  }

  @override
  void dispose() {
    ctrl.dispose();
    sc.dispose();
    super.dispose();
  }

  void save() => prefs.setString('chats', jsonEncode(chats));

  void jumpToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (sc.hasClients) sc.jumpTo(sc.position.maxScrollExtent);
    });
  }

  Future<void> send() async {
    final text = ctrl.text.trim();
    if (text.isEmpty || busy) return;
    ctrl.clear();
    final m = chats[cur]['m'] as List;
    if (m.isEmpty) chats[cur]['title'] = text.length > 30 ? text.substring(0, 30) : text;
    m.add({'r': 'user', 't': text});
    final hist = List<Map>.from(m);
    final reply = {'r': 'assistant', 't': ''};
    m.add(reply);
    save();
    setState(() => busy = true);
    try {
      await for (final s in ask(hist)) {
        reply['t'] = reply['t']! + s;
        if (mounted) setState(() {});
        jumpToEnd();
      }
      if (reply['t']!.isEmpty) reply['t'] = '⚠️ Empty response';
    } catch (e) {
      reply['t'] = '${reply['t']}\n⚠️ $e'.trim();
    }
    busy = false;
    save();
    if (mounted) setState(() {});
  }

  void deleteChat(int i) {
    if (busy) return; // FIX 6: no deleting while a reply is streaming (indexes could shift)
    setState(() {
      chats.removeAt(i);
      if (chats.isEmpty) chats.add(newChat());
      cur = 0;
    });
    save();
  }

  @override
  Widget build(BuildContext c) {
    final m = chats[cur]['m'] as List;
    return Scaffold(
      appBar: AppBar(title: const Text('JamalsGPT'), backgroundColor: Colors.transparent),
      drawer: Drawer(
        child: SafeArea(
          child: Column(children: [
            ListTile(
                leading: const Icon(Icons.add),
                title: Text(t('new')),
                onTap: () {
                  if (busy) return;
                  setState(() {
                    chats.insert(0, newChat());
                    cur = 0;
                  });
                  save();
                  Navigator.pop(c);
                }),
            Expanded(
              child: ListView.builder(
                itemCount: chats.length,
                itemBuilder: (_, i) => ListTile(
                  selected: i == cur,
                  title: Text(chats[i]['title'], maxLines: 1, overflow: TextOverflow.ellipsis),
                  onTap: () {
                    if (busy) return;
                    setState(() => cur = i);
                    Navigator.pop(c);
                  },
                  trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => deleteChat(i)),
                ),
              ),
            ),
            ListTile(
                leading: const Icon(Icons.settings),
                title: Text(t('settings')),
                onTap: () async {
                  Navigator.pop(c);
                  await Navigator.push(c, MaterialPageRoute(builder: (_) => const Settings()));
                  if (mounted) setState(() {});
                }),
          ]),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: ListView.builder(
            controller: sc,
            padding: const EdgeInsets.all(12),
            itemCount: m.length,
            itemBuilder: (_, i) {
              final x = m[i];
              final u = x['r'] == 'user';
              return Align(
                alignment: u ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(c).size.width * .85),
                  decoration: BoxDecoration(
                      color: u ? const Color(0xFF3A2F7A) : const Color(0xFF17171F),
                      borderRadius: BorderRadius.circular(16)),
                  child: SelectableText(x['t'] as String),
                ),
              );
            },
          ),
        ),
        if (busy) const LinearProgressIndicator(),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: ctrl,
                  minLines: 1,
                  maxLines: 5,
                  decoration: InputDecoration(
                      hintText: t('hint'),
                      filled: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(24), borderSide: BorderSide.none)),
                ),
              ),
              IconButton.filled(onPressed: send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}

class Settings extends StatefulWidget {
  const Settings({super.key});
  @override
  State<Settings> createState() => _SettingsState();
}

class _SettingsState extends State<Settings> {
  String p = g('provider', 'gemini'), lang = g('lang', 'bn');
  final key = TextEditingController(), model = TextEditingController();

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    key.dispose();
    model.dispose();
    super.dispose();
  }

  void load() {
    key.text = g('key_$p', '');
    model.text = modelFor(p);
  }

  void stash() {
    prefs.setString('key_$p', key.text.trim());
    prefs.setString('model_$p', model.text.trim().isEmpty ? defModel(p) : model.text.trim());
  }

  Future<void> save() async {
    stash();
    await prefs.setString('provider', p);
    await prefs.setString('lang', lang);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text(t('settings'))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            value: kStr.containsKey(lang) ? lang : 'bn',
            decoration: InputDecoration(labelText: t('lang')),
            items: const [DropdownMenuItem(value: 'bn', child: Text('বাংলা')), DropdownMenuItem(value: 'en', child: Text('English'))],
            onChanged: (v) => setState(() => lang = v!),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: kProviders.contains(p) ? p : kProviders.first,
            decoration: InputDecoration(labelText: t('provider')),
            items: [for (final x in kProviders) DropdownMenuItem(value: x, child: Text(kNames[x]!))],
            onChanged: (v) => setState(() {
              stash();
              p = v!;
              load();
            }),
          ),
          const SizedBox(height: 12),
          TextField(controller: key, obscureText: true, decoration: InputDecoration(labelText: t('key'))),
          const SizedBox(height: 12),
          TextField(controller: model, decoration: InputDecoration(labelText: t('model'))),
          const SizedBox(height: 12),
          Text(t('backup'), style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 20),
          FilledButton(onPressed: save, child: Text(t('save'))),
        ]),
      );
}
