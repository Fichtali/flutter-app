// ══════════════════════════════════════════════════════════════════════════════
//  TripShare — main.dart
//  Offline photo & video sharing on local WiFi / hotspot
//  WITH FULL VIDEO PLAYBACK SUPPORT
// ══════════════════════════════════════════════════════════════════════════════

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart' as shelf_router;

// ── Video packages ──────────────────────────────────────────────────────────
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:path_provider/path_provider.dart';

// ─────────────────────────────────────────
//  DESIGN TOKENS
// ─────────────────────────────────────────

class T {
  // Primary gradient: deep ocean blue → warm horizon gold
  static const oceanDeep   = Color(0xFF1A3A5C); // darkest navy
  static const oceanMid    = Color(0xFF1E6091); // rich sea blue
  static const horizon     = Color(0xFFE8A838); // warm gold/amber
  static const horizonSoft = Color(0xFFF5C96A); // light amber

  // Surface
  static const bg          = Color(0xFFF0F4F8); // cool pale blue-grey
  static const surface     = Color(0xFFFFFFFF);
  static const surfaceCard = Color(0xFFFFFFFF);

  // Accents
  static const teal        = Color(0xFF0B8A8F); // deep teal for success/online
  static const tealLight   = Color(0xFFE0F5F5);
  static const coral       = Color(0xFFE05C3A); // warm coral for error/delete
  static const coralLight  = Color(0xFFFAEDE9);
  static const sand        = Color(0xFFFBF3E3); // warm sand for guest card

  // Text
  static const ink         = Color(0xFF111827);
  static const inkMid      = Color(0xFF4B5563);
  static const inkFaint    = Color(0xFF9CA3AF);

  // Terminal
  static const termBg      = Color(0xFF0D1B2A);
  static const termGreen   = Color(0xFF4ADE80);
  static const termDim     = Color(0xFF334155);
}

// Gradients
const LinearGradient kOceanGradient = LinearGradient(
  colors: [T.oceanDeep, T.oceanMid],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient kHorizonGradient = LinearGradient(
  colors: [T.horizon, T.horizonSoft],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient kSkyGradient = LinearGradient(
  colors: [T.oceanMid, T.teal],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

// Text styles
const kDisplayStyle = TextStyle(
  fontSize: 28,
  fontWeight: FontWeight.w800,
  color: T.ink,
  letterSpacing: -0.8,
  height: 1.15,
);

const kHeadStyle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.w700,
  color: T.ink,
  letterSpacing: -0.3,
);

const kSubStyle = TextStyle(
  fontSize: 14,
  color: T.inkMid,
  height: 1.55,
);

const kLabelStyle = TextStyle(
  fontSize: 11,
  fontWeight: FontWeight.w700,
  color: T.inkFaint,
  letterSpacing: 0.8,
);

// ─────────────────────────────────────────
//  VIDEO THUMBNAIL HELPER
// ─────────────────────────────────────────

class VideoThumbnailHelper {
  static final Map<String, String> _thumbnailCache = {};

  static Future<Widget> getThumbnail(File videoFile) async {
    final filePath = videoFile.path;
    
    if (_thumbnailCache.containsKey(filePath)) {
      final cachedPath = _thumbnailCache[filePath]!;
      if (await File(cachedPath).exists()) {
        return Image.file(
          File(cachedPath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
        );
      }
    }

    try {
      final thumbnailPath = await VideoThumbnail.thumbnailFile(
        video: filePath,
        thumbnailPath: (await getTemporaryDirectory()).path,
        imageFormat: ImageFormat.JPEG,
        maxHeight: 300,
        maxWidth: 300,
        quality: 80,
      );

      if (thumbnailPath != null) {
        _thumbnailCache[filePath] = thumbnailPath;
        return Image.file(
          File(thumbnailPath),
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => const _VideoPlaceholder(),
        );
      }
    } catch (e) {
      print('Error generating video thumbnail: $e');
    }

    return const _VideoPlaceholder();
  }

  static void clearCache() {
    _thumbnailCache.clear();
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF667eea), Color(0xFF764ba2)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('🎬', style: TextStyle(fontSize: 32)),
            SizedBox(height: 4),
            Text(
              'Video',
              style: TextStyle(color: Colors.white70, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────
//  SHARED APP STATE (simple singleton)
// ─────────────────────────────────────────

class TripState {
  static final TripState _i = TripState._();
  factory TripState() => _i;
  TripState._();

  List<File>   mediaFiles  = [];
  HttpServer?  server;
  bool         serverUp    = false;
  String       serverIP    = '';
  List<String> activityLog = [];

  // username → [{file, time}]
  Map<String, List<Map<String, String>>> guestLog = {};

  final List<VoidCallback> _listeners = [];
  void addListener(VoidCallback fn)    => _listeners.add(fn);
  void removeListener(VoidCallback fn) => _listeners.remove(fn);
  void notify() { for (final fn in _listeners) fn(); }

  String get _ts {
    final n = DateTime.now();
    return '${_p(n.hour)}:${_p(n.minute)}:${_p(n.second)}';
  }
  String _p(int v) => v.toString().padLeft(2, '0');

  void log(String msg) {
    activityLog.insert(0, '$_ts  $msg');
    if (activityLog.length > 200) activityLog.removeLast();
    notify();
  }

  void recordDownload(String user, String file) {
    guestLog.putIfAbsent(user, () => []);
    guestLog[user]!.add({'file': file, 'time': _ts});
    log('⬇  $user  ›  $file');
  }

  String fileName(File f) => f.path.split(Platform.pathSeparator).last;
}

// ─────────────────────────────────────────
//  ROOT
// ─────────────────────────────────────────

void main() {
  runApp(const TripShareApp());
}

class TripShareApp extends StatelessWidget {
  const TripShareApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TripShare',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: T.bg,
        colorSchemeSeed: T.oceanMid,
        fontFamily: 'SF Pro Display',
      ),
      home: const SplashScreen(),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  SPLASH / ROLE GATE
// ══════════════════════════════════════════════════════════════════════════════

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(gradient: kOceanGradient),
          ),
          Positioned(
            right: -80, top: -60,
            child: Container(
              width: 260, height: 260,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: T.horizon.withOpacity(0.15),
              ),
            ),
          ),
          Positioned(
            left: -40, bottom: 120,
            child: Container(
              width: 180, height: 180,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: T.teal.withOpacity(0.12),
              ),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28),
              child: Column(
                children: [
                  const SizedBox(height: 60),
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      gradient: kHorizonGradient,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: T.horizon.withOpacity(0.5),
                          blurRadius: 28, offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.flight_takeoff_rounded,
                      color: Colors.white, size: 38,
                    ),
                  ),
                  const SizedBox(height: 28),
                  const Text(
                    'TripShare',
                    style: TextStyle(
                      fontSize: 36, fontWeight: FontWeight.w800,
                      color: Colors.white, letterSpacing: -1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Share every moment.\nNo internet needed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15, color: Colors.white.withOpacity(0.65),
                      height: 1.55,
                    ),
                  ),
                  const Spacer(),
                  _RoleCard(
                    gradient: kHorizonGradient,
                    icon: Icons.admin_panel_settings_rounded,
                    eyebrow: 'HOST',
                    title: "I'm hosting the trip",
                    subtitle: 'Upload media, start the server,\nmanage what friends can see',
                    onTap: () => Navigator.push(
                      context,
                      _slide(const AdminPinScreen()),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _RoleCard(
                    gradient: kSkyGradient,
                    icon: Icons.people_alt_rounded,
                    eyebrow: 'GUEST',
                    title: "I'm on the trip too",
                    subtitle: 'Browse the gallery and save\nthe photos you love',
                    onTap: () => Navigator.push(
                      context,
                      _slide(const GuestNameScreen()),
                    ),
                  ),
                  const SizedBox(height: 40),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: Colors.white.withOpacity(0.15)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.wifi_rounded, size: 14, color: Colors.white.withOpacity(0.7)),
                        const SizedBox(width: 7),
                        Text(
                          'Works on local WiFi & mobile hotspot only',
                          style: TextStyle(
                            fontSize: 12, color: Colors.white.withOpacity(0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleCard extends StatelessWidget {
  final LinearGradient gradient;
  final IconData icon;
  final String eyebrow;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _RoleCard({
    super.key,
    required this.gradient,
    required this.icon,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.08),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withOpacity(0.14), width: 1.2),
        ),
        child: Row(
          children: [
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                gradient: gradient,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(icon, color: Colors.white, size: 26),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    eyebrow,
                    style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.w800,
                      color: Colors.white.withOpacity(0.45), letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700, color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12, color: Colors.white.withOpacity(0.55), height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              size: 14, color: Colors.white.withOpacity(0.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  ADMIN — PIN SCREEN
// ══════════════════════════════════════════════════════════════════════════════

class AdminPinScreen extends StatefulWidget {
  const AdminPinScreen({super.key});

  @override
  State<AdminPinScreen> createState() => _AdminPinScreenState();
}

class _AdminPinScreenState extends State<AdminPinScreen>
    with SingleTickerProviderStateMixin {
  final List<String> _digits = [];
  bool _wrong = false;
  late AnimationController _shake;
  late Animation<double> _shakeAnim;

  static const _correctPin = '1234';

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 380),
    );
    _shakeAnim = TweenSequence([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -6.0),  weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6.0, end: 6.0),   weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6.0, end: 0.0),    weight: 1),
    ]).animate(_shake);
  }

  @override
  void dispose() { _shake.dispose(); super.dispose(); }

  void _press(String d) {
    if (_digits.length >= 4) return;
    setState(() { _digits.add(d); _wrong = false; });
    if (_digits.length == 4) _check();
  }

  void _del() {
    if (_digits.isEmpty) return;
    setState(() => _digits.removeLast());
  }

  void _check() async {
    await Future.delayed(const Duration(milliseconds: 120));
    if (_digits.join() == _correctPin) {
      if (!mounted) return;
      Navigator.pushReplacement(context, _slide(const AdminDashboard()));
    } else {
      _shake.forward(from: 0);
      setState(() { _digits.clear(); _wrong = true; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(decoration: const BoxDecoration(gradient: kOceanGradient)),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const Spacer(),
                Container(
                  width: 72, height: 72,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white.withOpacity(0.18)),
                  ),
                  child: const Icon(Icons.lock_rounded, color: Colors.white, size: 34),
                ),
                const SizedBox(height: 22),
                const Text(
                  'Host PIN',
                  style: TextStyle(
                    fontSize: 26, fontWeight: FontWeight.w800,
                    color: Colors.white, letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 6),
                AnimatedOpacity(
                  opacity: 1, duration: Duration.zero,
                  child: Text(
                    _wrong ? 'Incorrect PIN — try again' : 'Enter your 4-digit PIN',
                    style: TextStyle(
                      fontSize: 14,
                      color: _wrong
                          ? T.horizon
                          : Colors.white.withOpacity(0.55),
                    ),
                  ),
                ),
                const SizedBox(height: 38),
                AnimatedBuilder(
                  animation: _shakeAnim,
                  builder: (_, child) => Transform.translate(
                    offset: Offset(_shakeAnim.value, 0),
                    child: child,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: List.generate(4, (i) {
                      final filled = i < _digits.length;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOut,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        width: filled ? 20 : 16,
                        height: filled ? 20 : 16,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: filled
                              ? (_wrong ? T.coral : T.horizon)
                              : Colors.transparent,
                          border: Border.all(
                            color: filled
                                ? (_wrong ? T.coral : T.horizon)
                                : Colors.white.withOpacity(0.35),
                            width: 2,
                          ),
                        ),
                      );
                    }),
                  ),
                ),
                const Spacer(),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    children: [
                      for (final row in [
                        ['1','2','3'],
                        ['4','5','6'],
                        ['7','8','9'],
                        ['',  '0', '⌫'],
                      ])
                        Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: row.map((k) {
                              if (k.isEmpty) return const SizedBox(width: 76);
                              return _PinKey(
                                label: k,
                                isBackspace: k == '⌫',
                                onTap: () => k == '⌫' ? _del() : _press(k),
                              );
                            }).toList(),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Default PIN: 1234',
                  style: TextStyle(
                    fontSize: 11, color: Colors.white.withOpacity(0.25),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PinKey extends StatelessWidget {
  final String label;
  final bool isBackspace;
  final VoidCallback onTap;

  const _PinKey({
    super.key,
    required this.label,
    required this.isBackspace,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 76, height: 76,
        decoration: BoxDecoration(
          color: isBackspace
              ? Colors.transparent
              : Colors.white.withOpacity(0.10),
          borderRadius: BorderRadius.circular(22),
          border: isBackspace
              ? null
              : Border.all(color: Colors.white.withOpacity(0.12)),
        ),
        child: Center(
          child: isBackspace
              ? Icon(Icons.backspace_outlined, color: Colors.white.withOpacity(0.5), size: 22)
              : Text(
                  label,
                  style: const TextStyle(
                    fontSize: 24, fontWeight: FontWeight.w500, color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  GUEST — NAME SCREEN
// ══════════════════════════════════════════════════════════════════════════════

class GuestNameScreen extends StatefulWidget {
  const GuestNameScreen({super.key});

  @override
  State<GuestNameScreen> createState() => _GuestNameScreenState();
}

class _GuestNameScreenState extends State<GuestNameScreen> {
  final _ctrl = TextEditingController();
  bool _err = false;

  void _go() async {
    final name = _ctrl.text.trim();
    if (name.isEmpty) { setState(() => _err = true); return; }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('guest_name', name);

    final ts = TripState();
    if (!ts.guestLog.containsKey(name)) {
      ts.guestLog[name] = [];
      ts.log('👤 $name joined');
    }

    if (!mounted) return;
    Navigator.pushReplacement(
      context, _slide(GuestGalleryScreen(username: name)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1E6091), T.teal],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ),
                const Spacer(),
                const Text('👋', style: TextStyle(fontSize: 52)),
                const SizedBox(height: 20),
                const Text(
                  "What's your name?",
                  style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.w800,
                    color: Colors.white, letterSpacing: -0.6,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'So the host knows who saved what',
                  style: TextStyle(
                    fontSize: 15, color: Colors.white.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 40),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.15),
                          blurRadius: 28, offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('YOUR NAME', style: kLabelStyle),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _ctrl,
                          autofocus: true,
                          textCapitalization: TextCapitalization.words,
                          onSubmitted: (_) => _go(),
                          style: const TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700,
                            color: T.ink,
                          ),
                          decoration: InputDecoration(
                            hintText: 'e.g. Sara',
                            hintStyle: const TextStyle(
                              fontSize: 20, fontWeight: FontWeight.w400,
                              color: T.inkFaint,
                            ),
                            errorText: _err ? 'Please enter your name' : null,
                            filled: true,
                            fillColor: T.bg,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: BorderSide.none,
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(14),
                              borderSide: const BorderSide(color: T.teal, width: 2),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 18, vertical: 16,
                            ),
                            prefixIcon: const Icon(
                              Icons.person_outline_rounded, color: T.teal,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          onPressed: _go,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: T.teal,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(vertical: 17),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          child: const Text(
                            'Open Gallery',
                            style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  ADMIN DASHBOARD
// ══════════════════════════════════════════════════════════════════════════════

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard>
    with SingleTickerProviderStateMixin {
  final _ts = TripState();
  late TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _ts.addListener(_rebuild);
    _ts.log('✅ Host signed in');
  }

  @override
  void dispose() {
    _ts.removeListener(_rebuild);
    _tabs.dispose();
    super.dispose();
  }

  void _rebuild() { if (mounted) setState(() {}); }

  Future<void> _startServer() async {
    try {
      String ip = 'Unknown';
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback) { ip = addr.address; break; }
        }
        if (ip != 'Unknown') break;
      }

      final router = shelf_router.Router();

      router.get('/', (Request req) {
        final user = req.requestedUri.queryParameters['user'];
        if (user == null || user.trim().isEmpty) {
          return Response.ok(
            _htmlLogin(), headers: {'content-type': 'text/html; charset=utf-8'},
          );
        }
        final clean = user.trim();
        if (!_ts.guestLog.containsKey(clean)) {
          _ts.guestLog[clean] = [];
          _ts.log('👤 $clean joined via browser');
          _ts.notify();
        }
        return Response.ok(
          _htmlGallery(clean), headers: {'content-type': 'text/html; charset=utf-8'},
        );
      });

      router.get('/img/<name>', (Request req, String name) {
        try {
          final f = _ts.mediaFiles.firstWhere(
            (f) => Uri.encodeComponent(_ts.fileName(f)) == name
                || _ts.fileName(f) == name,
          );
          final fname = _ts.fileName(f);
          final isVideo = fname.endsWith('.mp4') || fname.endsWith('.mov');
          if (isVideo) {
            return Response.ok('', headers: {'content-type': 'text/plain'});
          }
          return Response.ok(
            f.openRead(),
            headers: {'Content-Type': 'image/jpeg'},
          );
        } catch (_) {
          return Response.notFound('Not found');
        }
      });

      router.get('/dl/<name>', (Request req, String name) {
        final user = req.requestedUri.queryParameters['user'] ?? 'Unknown';
        try {
          final f = _ts.mediaFiles.firstWhere(
            (f) => Uri.encodeComponent(_ts.fileName(f)) == name
                || _ts.fileName(f) == name,
          );
          final fname = _ts.fileName(f);
          _ts.recordDownload(user, fname);
          _ts.notify();
          final isVideo = fname.endsWith('.mp4') || fname.endsWith('.mov');
          return Response.ok(
            f.openRead(),
            headers: {
              'Content-Type': isVideo ? 'video/mp4' : 'image/jpeg',
              'Content-Disposition': 'attachment; filename="$fname"',
            },
          );
        } catch (_) {
          return Response.notFound('File not found');
        }
      });

      final server = await shelf_io.serve(
        const Pipeline().addMiddleware(logRequests()).addHandler(router.call),
        InternetAddress.anyIPv4, 8080,
      );

      _ts.server   = server;
      _ts.serverUp = true;
      _ts.serverIP = ip;
      _ts.log('🚀 Server live — http://$ip:8080');
      _ts.notify();
    } catch (e) {
      _ts.log('❌ Failed: $e');
    }
  }

  Future<void> _addMedia() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'mp4', 'mov'],
      allowMultiple: true,
    );
    if (result == null) return;
    for (final path in result.paths) {
      if (path == null) continue;
      final f = File(path);
      if (!_ts.mediaFiles.any((x) => x.path == path)) {
        _ts.mediaFiles.add(f);
        _ts.log('📁 Added: ${_ts.fileName(f)}');
        // Pre-generate thumbnail in background
        if (_ts.fileName(f).endsWith('.mp4') || _ts.fileName(f).endsWith('.mov')) {
          VideoThumbnailHelper.getThumbnail(f);
        }
      }
    }
    _ts.notify();
  }

  void _deleteMedia(int i) {
    final name = _ts.fileName(_ts.mediaFiles[i]);
    _ts.mediaFiles.removeAt(i);
    _ts.log('🗑  Removed: $name');
    _ts.notify();
    VideoThumbnailHelper.clearCache();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          _AdminHeader(
            isUp: _ts.serverUp,
            ip: _ts.serverIP,
            onStart: _startServer,
            onBack: () => Navigator.pop(context),
          ),
          Container(
            color: T.surface,
            child: TabBar(
              controller: _tabs,
              labelColor: T.oceanMid,
              unselectedLabelColor: T.inkFaint,
              indicatorColor: T.horizon,
              indicatorWeight: 3,
              labelStyle: const TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3,
              ),
              tabs: const [
                Tab(icon: Icon(Icons.photo_library_rounded, size: 19), text: 'Gallery'),
                Tab(icon: Icon(Icons.people_rounded, size: 19), text: 'Guests'),
                Tab(icon: Icon(Icons.terminal_rounded, size: 19), text: 'Logs'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _AdminGalleryTab(
                  files: _ts.mediaFiles,
                  onAdd: _addMedia,
                  onDelete: _deleteMedia,
                  ts: _ts,
                ),
                _GuestsTab(log: _ts.guestLog),
                _LogsTab(logs: _ts.activityLog),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _htmlLogin() => '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TripShare</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{
  font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;
  background:linear-gradient(135deg,#1A3A5C 0%,#1E6091 60%,#0B8A8F 100%);
  min-height:100vh;display:flex;align-items:center;
  justify-content:center;padding:20px
}
.card{
  background:#fff;border-radius:28px;padding:40px 32px;
  max-width:380px;width:100%;text-align:center;
  box-shadow:0 24px 64px rgba(0,0,0,0.18)
}
.icon{
  width:70px;height:70px;margin:0 auto 22px;border-radius:22px;
  background:linear-gradient(135deg,#E8A838,#F5C96A);
  display:flex;align-items:center;justify-content:center;font-size:32px;
  box-shadow:0 10px 28px rgba(232,168,56,0.45)
}
h1{font-size:26px;font-weight:800;color:#111827;letter-spacing:-0.5px;margin-bottom:6px}
p{color:#6B7280;font-size:14px;line-height:1.55;margin-bottom:30px}
label{display:block;text-align:left;font-size:11px;font-weight:700;
  color:#9CA3AF;letter-spacing:0.8px;margin-bottom:8px}
input{
  width:100%;padding:16px 18px;border:2px solid #E5E7EB;
  border-radius:14px;font-size:17px;font-weight:600;color:#111827;
  background:#F9FAFB;outline:none;transition:border 0.2s,background 0.2s
}
input:focus{border-color:#0B8A8F;background:#fff}
input::placeholder{font-weight:400;color:#D1D5DB}
button{
  width:100%;margin-top:16px;padding:17px;
  background:linear-gradient(135deg,#1E6091,#0B8A8F);
  color:#fff;border:none;border-radius:14px;font-size:16px;
  font-weight:700;cursor:pointer;transition:opacity 0.2s;
  letter-spacing:0.2px
}
button:active{opacity:0.85}
.hint{margin-top:20px;font-size:12px;color:#D1D5DB}
</style>
</head>
<body>
<div class="card">
  <div class="icon">✈️</div>
  <h1>TripShare</h1>
  <p>Your name is needed before you can browse the vacation gallery.</p>
  <form method="GET" action="/">
    <label>YOUR NAME</label>
    <input type="text" name="user" placeholder="e.g. Sara" required autofocus autocomplete="off"/>
    <button type="submit">Open Gallery</button>
  </form>
  <p class="hint">Local network only · No internet required</p>
</div>
</body>
</html>''';

  String _htmlGallery(String user) {
    final files = _ts.mediaFiles;
    String items = '';

    if (files.isEmpty) {
      items = '<div class="empty">🌴<br>Gallery is empty.<br>Ask the host to add some photos!</div>';
    } else {
      for (final f in files) {
        final name = _ts.fileName(f);
        final enc  = Uri.encodeComponent(name);
        final uEnc = Uri.encodeComponent(user);
        final isVid = name.endsWith('.mp4') || name.endsWith('.mov');
        final preview = isVid
            ? '<div class="video-cover">🎬</div>'
            : '<img class="cover" src="/img/$enc" alt="" loading="lazy">';
        items += '''
<div class="card">
  $preview
  <div class="meta">
    <div class="fname">${name.length > 24 ? '${name.substring(0, 22)}…' : name}</div>
    <a class="dlbtn" href="/dl/$enc?user=$uEnc">⬇ Save to device</a>
  </div>
</div>''';
      }
    }

    return '''<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>TripShare · Gallery</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;background:#F0F4F8;color:#111827}
header{
  background:#fff;padding:14px 20px;
  display:flex;justify-content:space-between;align-items:center;
  box-shadow:0 2px 12px rgba(0,0,0,0.05);position:sticky;top:0;z-index:10
}
.logo{font-size:18px;font-weight:800;color:#1E6091}
.badge{
  background:#E0F5F5;color:#0B8A8F;padding:6px 14px;
  border-radius:20px;font-size:13px;font-weight:700
}
.grid{
  display:grid;grid-template-columns:repeat(auto-fill,minmax(155px,1fr));
  gap:14px;padding:20px;max-width:900px;margin:0 auto
}
.card{
  background:#fff;border-radius:18px;overflow:hidden;
  box-shadow:0 4px 16px rgba(0,0,0,0.05);border:1px solid #E5E7EB
}
.cover,.video-cover{width:100%;height:140px;display:block}
.cover{object-fit:cover}
.video-cover{
  background:linear-gradient(135deg,#667eea,#764ba2);
  display:flex;align-items:center;justify-content:center;
  font-size:46px
}
.meta{padding:12px}
.fname{font-size:12px;font-weight:600;color:#374151;margin-bottom:9px;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.dlbtn{
  display:block;background:linear-gradient(135deg,#1E6091,#0B8A8F);
  color:#fff;text-decoration:none;text-align:center;
  padding:10px 0;border-radius:10px;font-size:12px;font-weight:700
}
.dlbtn:active{opacity:0.85}
.empty{
  text-align:center;padding:80px 20px;color:#9CA3AF;
  font-size:16px;line-height:1.8;grid-column:1/-1
}
</style>
</head>
<body>
<header>
  <span class="logo">✈️ TripShare</span>
  <span class="badge">👤 $user</span>
</header>
<div class="grid">$items</div>
</body>
</html>''';
  }
}

// ─────────────────────────────────────────
//  ADMIN HEADER WIDGET
// ─────────────────────────────────────────

class _AdminHeader extends StatelessWidget {
  final bool isUp;
  final String ip;
  final VoidCallback onStart;
  final VoidCallback onBack;

  const _AdminHeader({
    required this.isUp, required this.ip,
    required this.onStart, required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(gradient: kOceanGradient),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 16, 20),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 18),
                    onPressed: onBack,
                  ),
                  const Expanded(
                    child: Text(
                      'Host Dashboard',
                      style: TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.shield_rounded, color: Colors.white, size: 13),
                        const SizedBox(width: 5),
                        const Text(
                          'ADMIN',
                          style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.w800,
                            color: Colors.white, letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              GestureDetector(
                onTap: isUp
                    ? () {
                        Clipboard.setData(ClipboardData(text: 'http://$ip:8080'));
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('Link copied to clipboard'),
                            backgroundColor: T.teal,
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 400),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: isUp
                        ? T.teal.withOpacity(0.22)
                        : Colors.white.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isUp
                          ? T.teal.withOpacity(0.5)
                          : Colors.white.withOpacity(0.15),
                    ),
                  ),
                  child: Row(
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 10, height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isUp ? T.horizonSoft : Colors.white.withOpacity(0.3),
                          boxShadow: isUp
                              ? [BoxShadow(color: T.horizonSoft.withOpacity(0.7), blurRadius: 6)]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              isUp ? 'Server is live' : 'Server is offline',
                              style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white,
                              ),
                            ),
                            Text(
                              isUp
                                  ? 'http://$ip:8080  ·  tap to copy'
                                  : 'Start the server so friends can connect',
                              style: TextStyle(
                                fontSize: 11, color: Colors.white.withOpacity(0.55),
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (!isUp)
                        ElevatedButton(
                          onPressed: onStart,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: T.horizon,
                            foregroundColor: Colors.white,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(11),
                            ),
                          ),
                          child: const Text(
                            'Start',
                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                          ),
                        )
                      else
                        Icon(Icons.copy_rounded, size: 16, color: Colors.white.withOpacity(0.5)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  ADMIN — GALLERY TAB
// ──────────────────────────────────────────────────────────────────────────────

class _AdminGalleryTab extends StatelessWidget {
  final List<File> files;
  final VoidCallback onAdd;
  final void Function(int) onDelete;
  final TripState ts;

  const _AdminGalleryTab({
    required this.files,
    required this.onAdd,
    required this.onDelete,
    required this.ts,
  });

  @override
  Widget build(BuildContext context) {
    final imgCount = files.where((f) {
      final n = ts.fileName(f);
      return n.endsWith('.jpg') || n.endsWith('.jpeg') || n.endsWith('.png');
    }).length;
    final videoCount = files.length - imgCount;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              _StatPill(
                icon: Icons.image_rounded,
                label: '$imgCount Photos',
                color: T.oceanMid,
              ),
              const SizedBox(width: 10),
              _StatPill(
                icon: Icons.videocam_rounded,
                label: '$videoCount Videos',
                color: Colors.purple,
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: onAdd,
                style: FilledButton.styleFrom(
                  backgroundColor: T.horizon,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  'Add',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: files.isEmpty
              ? _EmptyState(
                  icon: Icons.photo_library_outlined,
                  title: 'Gallery is empty',
                  sub: 'Tap Add to share photos and videos\nwith your friends on this trip',
                  buttonLabel: 'Add first media',
                  onButton: onAdd,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: files.length,
                  itemBuilder: (_, i) {
                    final name = ts.fileName(files[i]);
                    final isVideo = name.endsWith('.mp4') || name.endsWith('.mov');
                    return _MediaRow(
                      file: files[i],
                      name: name,
                      isVideo: isVideo,
                      onDelete: () => onDelete(i),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _StatPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _StatPill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withOpacity(0.09),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

class _MediaRow extends StatefulWidget {
  final File file;
  final String name;
  final bool isVideo;
  final VoidCallback onDelete;

  const _MediaRow({
    required this.file,
    required this.name,
    required this.isVideo,
    required this.onDelete,
  });

  @override
  State<_MediaRow> createState() => _MediaRowState();
}

class _MediaRowState extends State<_MediaRow> {
  Widget? _thumbnail;

  @override
  void initState() {
    super.initState();
    if (widget.isVideo) {
      _loadThumbnail();
    }
  }

  Future<void> _loadThumbnail() async {
    final thumbnail = await VideoThumbnailHelper.getThumbnail(widget.file);
    if (mounted) {
      setState(() {
        _thumbnail = thumbnail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: T.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(16)),
            child: SizedBox(
              width: 64,
              height: 64,
              child: widget.isVideo
                  ? (_thumbnail ?? Container(
                      color: Colors.grey[900],
                      child: const Center(
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ))
                  : Image.file(widget.file, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: T.ink,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.isVideo ? 'Video' : 'Photo',
                  style: const TextStyle(fontSize: 12, color: T.inkFaint),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: T.coral, size: 20),
            onPressed: widget.onDelete,
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  ADMIN — GUESTS TAB
// ──────────────────────────────────────────────────────────────────────────────

class _GuestsTab extends StatelessWidget {
  final Map<String, List<Map<String, String>>> log;

  const _GuestsTab({required this.log});

  @override
  Widget build(BuildContext context) {
    if (log.isEmpty) {
      return const _EmptyState(
        icon: Icons.people_outline_rounded,
        title: 'No guests yet',
        sub: 'Friends will appear here once\nthey connect and enter their name',
      );
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: log.entries.map((e) {
        final user      = e.key;
        final downloads = e.value;
        final initial   = user.isNotEmpty ? user[0].toUpperCase() : '?';

        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            color: T.surface,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 10, offset: const Offset(0, 3))],
          ),
          child: Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              leading: CircleAvatar(
                backgroundColor: T.oceanMid.withOpacity(0.12),
                radius: 22,
                child: Text(
                  initial,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800, fontSize: 16, color: T.oceanMid,
                  ),
                ),
              ),
              title: Text(
                user,
                style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: T.ink,
                ),
              ),
              subtitle: Text(
                '${downloads.length} file${downloads.length == 1 ? '' : 's'} downloaded',
                style: const TextStyle(fontSize: 12, color: T.inkFaint),
              ),
              children: downloads.isEmpty
                  ? [
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text(
                          'No downloads yet',
                          style: TextStyle(color: T.inkFaint, fontSize: 13),
                        ),
                      )
                    ]
                  : downloads.map((d) {
                      return ListTile(
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 0),
                        leading: const Icon(
                          Icons.check_circle_rounded, size: 16, color: T.teal,
                        ),
                        title: Text(
                          d['file'] ?? '',
                          style: const TextStyle(fontSize: 13, color: T.ink),
                        ),
                        trailing: Text(
                          d['time'] ?? '',
                          style: const TextStyle(fontSize: 11, color: T.inkFaint),
                        ),
                      );
                    }).toList(),
            ),
          ),
        );
      }).toList(),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  ADMIN — LOGS TAB
// ──────────────────────────────────────────────────────────────────────────────

class _LogsTab extends StatelessWidget {
  final List<String> logs;

  const _LogsTab({required this.logs});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: T.termBg,
      child: logs.isEmpty
          ? Center(
              child: Text(
                'Waiting for activity…',
                style: TextStyle(color: T.termDim, fontFamily: 'monospace', fontSize: 13),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: logs.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Text(
                  logs[i],
                  style: const TextStyle(
                    color: T.termGreen, fontFamily: 'monospace',
                    fontSize: 12, height: 1.4,
                  ),
                ),
              ),
            ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  GUEST GALLERY SCREEN
// ══════════════════════════════════════════════════════════════════════════════

class GuestGalleryScreen extends StatefulWidget {
  final String username;

  const GuestGalleryScreen({super.key, required this.username});

  @override
  State<GuestGalleryScreen> createState() => _GuestGalleryScreenState();
}

class _GuestGalleryScreenState extends State<GuestGalleryScreen> {
  final _ts = TripState();

  @override
  void initState() {
    super.initState();
    _ts.addListener(_rebuild);
  }

  @override
  void dispose() {
    _ts.removeListener(_rebuild);
    super.dispose();
  }

  void _rebuild() { if (mounted) setState(() {}); }

  bool _saved(String name) =>
      (_ts.guestLog[widget.username] ?? []).any((d) => d['file'] == name);

  @override
  Widget build(BuildContext context) {
    final files = _ts.mediaFiles;

    return Scaffold(
      backgroundColor: T.bg,
      body: Column(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF1E6091), T.teal],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 16, 18),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 18),
                      onPressed: () => Navigator.pop(context),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Trip Gallery',
                            style: TextStyle(
                              fontSize: 19, fontWeight: FontWeight.w800, color: Colors.white,
                            ),
                          ),
                          Text(
                            '${files.length} item${files.length == 1 ? '' : 's'} shared',
                            style: TextStyle(
                              fontSize: 12, color: Colors.white.withOpacity(0.6),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.person_rounded, color: Colors.white, size: 13),
                          const SizedBox(width: 5),
                          Text(
                            widget.username,
                            style: const TextStyle(
                              color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: files.isEmpty
                ? const _EmptyState(
                    icon: Icons.image_search_rounded,
                    title: 'Gallery is empty',
                    sub: "Nothing here yet.\nAsk the host to add some photos!",
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(14),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 0.8,
                    ),
                    itemCount: files.length,
                    itemBuilder: (_, i) {
                      final f = files[i];
                      final name = _ts.fileName(f);
                      final isVid = name.endsWith('.mp4') || name.endsWith('.mov');
                      final done = _saved(name);

                      return GestureDetector(
                        onTap: () => Navigator.push(
                          context,
                          _fade(GuestMediaViewer(
                            files: files,
                            initialIndex: i,
                            username: widget.username,
                          )),
                        ).then((_) => setState(() {})),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 250),
                          decoration: BoxDecoration(
                            color: T.surface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: done ? T.teal : Colors.transparent,
                              width: 2.5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: done
                                    ? T.teal.withOpacity(0.18)
                                    : Colors.black.withOpacity(0.06),
                                blurRadius: done ? 16 : 10,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: ClipRRect(
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(16),
                                  ),
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      isVid
                                          ? _VideoThumbnailWidget(file: f)
                                          : Image.file(f, fit: BoxFit.cover),
                                      if (done)
                                        Container(
                                          color: T.teal.withOpacity(0.25),
                                          child: const Center(
                                            child: Icon(
                                              Icons.check_circle_rounded,
                                              color: Colors.white,
                                              size: 38,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: T.ink,
                                      ),
                                    ),
                                    const SizedBox(height: 7),
                                    AnimatedContainer(
                                      duration: const Duration(milliseconds: 250),
                                      height: 34,
                                      decoration: BoxDecoration(
                                        gradient: done
                                            ? null
                                            : const LinearGradient(
                                                colors: [T.oceanMid, T.teal],
                                              ),
                                        color: done ? T.tealLight : null,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Center(
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              done ? Icons.check_rounded : Icons.download_rounded,
                                              size: 14,
                                              color: done ? T.teal : Colors.white,
                                            ),
                                            const SizedBox(width: 5),
                                            Text(
                                              done ? 'Saved' : 'Save photo',
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w700,
                                                color: done ? T.teal : Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  VIDEO THUMBNAIL WIDGET
// ──────────────────────────────────────────────────────────────────────────────

class _VideoThumbnailWidget extends StatefulWidget {
  final File file;

  const _VideoThumbnailWidget({required this.file});

  @override
  State<_VideoThumbnailWidget> createState() => _VideoThumbnailWidgetState();
}

class _VideoThumbnailWidgetState extends State<_VideoThumbnailWidget> {
  Widget? _thumbnail;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    final thumbnail = await VideoThumbnailHelper.getThumbnail(widget.file);
    if (mounted) {
      setState(() {
        _thumbnail = thumbnail;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _thumbnail ?? Container(
      color: Colors.grey[900],
      child: const Center(
        child: SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  SHARED — EMPTY STATE
// ──────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String sub;
  final String? buttonLabel;
  final VoidCallback? onButton;

  const _EmptyState({
    required this.icon, required this.title, required this.sub,
    this.buttonLabel, this.onButton,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72, height: 72,
              decoration: BoxDecoration(
                color: T.oceanMid.withOpacity(0.07),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(icon, size: 34, color: T.inkFaint),
            ),
            const SizedBox(height: 18),
            Text(title, style: kHeadStyle),
            const SizedBox(height: 8),
            Text(
              sub, textAlign: TextAlign.center, style: kSubStyle,
            ),
            if (buttonLabel != null && onButton != null) ...[
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: onButton,
                style: ElevatedButton.styleFrom(
                  backgroundColor: T.oceanMid,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(
                  buttonLabel!,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
//  GUEST — MEDIA VIEWER SCREEN (WITH VIDEO PLAYBACK)
// ══════════════════════════════════════════════════════════════════════════════

class GuestMediaViewer extends StatefulWidget {
  final List<File> files;
  final int initialIndex;
  final String username;

  const GuestMediaViewer({
    super.key,
    required this.files,
    required this.initialIndex,
    required this.username,
  });

  @override
  State<GuestMediaViewer> createState() => _GuestMediaViewerState();
}

class _GuestMediaViewerState extends State<GuestMediaViewer> {
  final _ts = TripState();
  late PageController _pageController;
  late int _currentIndex;
  bool _uiVisible = true;

  final Map<int, VideoPlayerController> _videoControllers = {};
  final Map<int, ChewieController> _chewieControllers = {};
  final Map<int, bool> _videoInitialized = {};
  final Map<int, bool> _videoLoading = {};

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initVideo(_currentIndex);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    for (var controller in _chewieControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _isSaved {
    final name = _ts.fileName(widget.files[_currentIndex]);
    return (_ts.guestLog[widget.username] ?? []).any((d) => d['file'] == name);
  }

  void _saveCurrentMedia() {
    if (_isSaved) return;
    final f = widget.files[_currentIndex];
    final name = _ts.fileName(f);
    
    _ts.recordDownload(widget.username, name);
    _ts.notify();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: Colors.white, size: 18),
            const SizedBox(width: 10),
            Text('Saved to device: $name'),
          ],
        ),
        backgroundColor: T.teal,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() {});
  }

  Future<void> _initVideo(int index) async {
    if (_videoControllers.containsKey(index)) return;
    if (_videoLoading[index] == true) return;

    final file = widget.files[index];
    final name = _ts.fileName(file);
    final isVideo = name.endsWith('.mp4') || name.endsWith('.mov');
    
    if (!isVideo) return;

    setState(() {
      _videoLoading[index] = true;
    });

    try {
      if (!await file.exists()) {
        print('Video file does not exist: ${file.path}');
        setState(() {
          _videoLoading[index] = false;
          _videoInitialized[index] = false;
        });
        return;
      }

      print('Loading video: ${file.path}');
      print('File size: ${await file.length()} bytes');

      final controller = VideoPlayerController.file(file);
      
      controller.addListener(() {
        if (controller.value.hasError) {
          print('Video error: ${controller.value.errorDescription}');
          if (mounted) {
            setState(() {
              _videoInitialized[index] = false;
              _videoLoading[index] = false;
            });
          }
        }
      });

      await controller.initialize();
      
      print('Video initialized! Duration: ${controller.value.duration}');

      final chewieController = ChewieController(
        videoPlayerController: controller,
        autoPlay: index == _currentIndex,
        looping: false,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: T.horizon,
          handleColor: T.horizon,
          backgroundColor: Colors.grey.shade800,
          bufferedColor: Colors.grey.shade600,
        ),
        placeholder: Container(
          color: Colors.black,
          child: const Center(
            child: CircularProgressIndicator(color: Colors.white),
          ),
        ),
        autoInitialize: true,
        allowFullScreen: true,
        allowMuting: true,
      );

      if (mounted) {
        setState(() {
          _videoControllers[index] = controller;
          _chewieControllers[index] = chewieController;
          _videoInitialized[index] = true;
          _videoLoading[index] = false;
        });
      }
    } catch (e) {
      print('Error initializing video: $e');
      if (mounted) {
        setState(() {
          _videoLoading[index] = false;
          _videoInitialized[index] = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load video: ${e.toString().substring(0, 50)}'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _pauseOtherVideos(int currentIndex) {
    for (var entry in _chewieControllers.entries) {
      if (entry.key != currentIndex && entry.value.isPlaying) {
        entry.value.pause();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.files.length;
    final saved = _isSaved;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          GestureDetector(
            onTap: () => setState(() => _uiVisible = !_uiVisible),
            child: PageView.builder(
              controller: _pageController,
              itemCount: total,
              onPageChanged: (index) {
                setState(() => _currentIndex = index);
                _pauseOtherVideos(index);
                if (!_videoControllers.containsKey(index)) {
                  _initVideo(index);
                }
              },
              itemBuilder: (context, i) {
                final file = widget.files[i];
                final name = _ts.fileName(file);
                final isVideo = name.endsWith('.mp4') || name.endsWith('.mov');

                if (isVideo) {
                  if (_videoLoading[i] == true) {
                    return Container(
                      color: Colors.black,
                      child: const Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.white),
                            SizedBox(height: 14),
                            Text(
                              'Loading video...',
                              style: TextStyle(color: Colors.white70, fontSize: 14),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_videoInitialized.containsKey(i) && _videoInitialized[i] == false) {
                    return Container(
                      color: Colors.black,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
                            const SizedBox(height: 14),
                            Text(
                              'Failed to load video',
                              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 14),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              name,
                              style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  _videoInitialized[i] = false;
                                  _videoControllers.remove(i);
                                  _chewieControllers.remove(i);
                                  _videoLoading[i] = false;
                                });
                                _initVideo(i);
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.white,
                                foregroundColor: Colors.black,
                              ),
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  if (_videoControllers.containsKey(i) && _chewieControllers.containsKey(i)) {
                    return Container(
                      color: Colors.black,
                      child: Chewie(
                        controller: _chewieControllers[i]!,
                      ),
                    );
                  }

                  return Container(
                    color: Colors.black,
                    child: const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: Colors.white),
                          SizedBox(height: 14),
                          Text(
                            'Preparing video...',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return InteractiveViewer(
                  minScale: 1.0,
                  maxScale: 4.0,
                  child: Center(
                    child: Image.file(file, fit: BoxFit.contain),
                  ),
                );
              },
            ),
          ),

          // Top bar
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            top: _uiVisible ? 0 : -120,
            left: 0, right: 0,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.black.withOpacity(0.7), Colors.transparent],
                ),
              ),
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _ts.fileName(widget.files[_currentIndex]),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${_currentIndex + 1} of $total',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _saveCurrentMedia,
                        style: TextButton.styleFrom(
                          backgroundColor: saved ? T.teal.withOpacity(0.2) : T.teal,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                        ),
                        icon: Icon(
                          saved ? Icons.check_circle_rounded : Icons.download_rounded,
                          size: 16,
                          color: saved ? T.teal : Colors.white,
                        ),
                        label: Text(
                          saved ? 'Saved' : 'Save',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: saved ? T.teal : Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Navigation buttons
          if (_uiVisible && _currentIndex > 0)
            Positioned(
              left: 12, top: 0, bottom: 0,
              child: Center(
                child: IconButton(
                  icon: const Icon(Icons.chevron_left_rounded, color: Colors.white60, size: 36),
                  onPressed: () {
                    _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                    );
                  },
                ),
              ),
            ),
          if (_uiVisible && _currentIndex < total - 1)
            Positioned(
              right: 12, top: 0, bottom: 0,
              child: Center(
                child: IconButton(
                  icon: const Icon(Icons.chevron_right_rounded, color: Colors.white60, size: 36),
                  onPressed: () {
                    _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeOutCubic,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
//  UTIL
// ──────────────────────────────────────────────────────────────────────────────

PageRouteBuilder _slide(Widget page) => PageRouteBuilder(
  pageBuilder: (_, a, __) => page,
  transitionsBuilder: (_, a, __, child) => SlideTransition(
    position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
        .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
    child: child,
  ),
  transitionDuration: const Duration(milliseconds: 320),
);

PageRouteBuilder _fade(Widget page) => PageRouteBuilder(
  pageBuilder: (_, a, __) => page,
  transitionsBuilder: (_, a, __, child) => FadeTransition(
    opacity: CurvedAnimation(parent: a, curve: Curves.easeIn),
    child: child,
  ),
  transitionDuration: const Duration(milliseconds: 220),
);