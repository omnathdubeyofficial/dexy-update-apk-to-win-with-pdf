import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:pdfx/pdfx.dart';

const int kServerPort = 8085;
const int kWsPort = 8086;
const String kIpKey = 'saved_server_ip';
const String kOrientationKey = 'screen_orientation_index';

/// Locks app to one orientation at a time; tap on home screen cycles 90°.
class ScreenOrientationController extends ChangeNotifier {
  ScreenOrientationController._();
  static final instance = ScreenOrientationController._();

  static const _orientations = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  static const _labels = [
    'LANDSCAPE',
    'LANDSCAPE FLIP',
    'PORTRAIT',
    'PORTRAIT FLIP',
  ];

  int _index = 0;
  int get index => _index;
  String get label => _labels[_index];
  double get turns => _index * 0.25;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _index = prefs.getInt(kOrientationKey) ?? 0;
    if (_index < 0 || _index >= _orientations.length) _index = 0;
    await apply();
  }

  Future<void> cycle() async {
    _index = (_index + 1) % _orientations.length;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(kOrientationKey, _index);
    await apply();
    notifyListeners();
  }

  Future<void> apply() async {
    await SystemChrome.setPreferredOrientations([_orientations[_index]]);
  }
}

const int kGalleryImageCount = 55;
final List<String> kGalleryImages =
    List.generate(kGalleryImageCount, (i) => 'assets/img/${i + 1}.jpg');

const int kPlansImageCount = 5;
final List<String> kPlansImages =
    List.generate(kPlansImageCount, (i) => 'assets/plans/${i + 1}.jpeg');

const List<String> kWalkthroughVideos = [
  'assets/video/walkvideo.mp4',
];

const List<String> kDronshootVideos = [
  'assets/video/DJI_20260612135953_0426_D.MP4',
  'assets/video/DJI_20260612140220_0428_D.MP4',
];

const List<String> kDevImages = [
  'assets/background/DJI_20260612133119_0412_D.JPG',
  // 'assets/background/DJI_20260612133119_0412_D.JPG',
];

/// Persistent in-memory caches so screens don't reload on every back navigation.
class DexyScreenCache {
  DexyScreenCache._();

  static final Set<String> _precachedAssets = {};
  static final Map<String, Map<String, Uint8List>> videoThumbs = {};
  static final Map<String, Map<String, String>> videoPaths = {};

  static PdfDocument? brochureDoc;
  static int brochurePageCount = 0;
  static final Map<int, Uint8List> brochurePages = {};
  static final Map<int, bool> brochurePageLoading = {};

  static Future<void> precacheAssets(BuildContext context, List<String> assets) async {
    for (final path in assets) {
      if (_precachedAssets.contains(path)) continue;
      try {
        await precacheImage(AssetImage(path), context);
        _precachedAssets.add(path);
      } catch (e) {
        debugPrint('[Cache] Precache failed for $path: $e');
      }
    }
  }

  static Future<void> ensureBrochureLoaded() async {
    if (brochureDoc != null) return;
    brochureDoc = await PdfDocument.openAsset('assets/brochure/brochure.pdf');
    brochurePageCount = brochureDoc!.pagesCount;
  }

  static Future<void> loadBrochurePage(int pageIdx) async {
    if (brochureDoc == null) return;
    if (brochurePages.containsKey(pageIdx) || brochurePageLoading[pageIdx] == true) {
      return;
    }
    if (pageIdx < 0 || pageIdx >= brochurePageCount) return;

    brochurePageLoading[pageIdx] = true;
    try {
      final page = await brochureDoc!.getPage(pageIdx + 1);
      final img = await page.render(
        width: page.width * 2,
        height: page.height * 2,
        format: PdfPageImageFormat.jpeg,
      );
      await page.close();
      if (img != null) brochurePages[pageIdx] = img.bytes;
    } catch (e) {
      debugPrint('[Cache] Brochure page $pageIdx error: $e');
    } finally {
      brochurePageLoading[pageIdx] = false;
    }
  }
}

// ─────────────────────────── THEME ───────────────────────────
class C {
  static const Color accent   = Color(0xFFFECD2A); // golden
  static const Color bg       = Color(0xFF080808);
  static const Color glassW   = Color(0x18FFFFFF);
}

// ─────────────────────────── DEXY LINK ───────────────────────────
class DexyLink {
  static final DexyLink _i = DexyLink._();
  static DexyLink get instance => _i;
  DexyLink._();

  String? savedIP;
  bool isConnected   = false;
  bool isWsConnected = false;
  bool isScanning    = false;
  WebSocketChannel? _ws;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  final List<void Function(bool)> _listeners = [];

  final _messageController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get onMessage => _messageController.stream;

  void addListener(void Function(bool) cb)    => _listeners.add(cb);
  void removeListener(void Function(bool) cb) => _listeners.remove(cb);
  void _notify(bool c) {
    isConnected = c;
    for (final cb in List.from(_listeners)) cb(c);
  }

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    savedIP = prefs.getString(kIpKey);
    _startLoop();
  }

  void _startLoop() {
    _reconnectTimer?.cancel();
    _tryConnect();
    _reconnectTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!isConnected) _tryConnect();
    });
  }

  Future<void> _tryConnect() async {
    if (isConnected || isScanning) return;
    if (savedIP != null && savedIP!.isNotEmpty) {
      final ok = await handshake(savedIP!);
      if (ok) return;
    }
    await _scan();
  }

  Future<bool> handshake(String ip, {bool save = true}) async {
    try {
      final res = await Dio().post(
        'http://$ip:$kServerPort/connect',
        data: jsonEncode({'ip': ip}),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(seconds: 3),
          receiveTimeout: const Duration(seconds: 3),
        ),
      );
      if (res.data.toString().trim() == 'MATCHED') {
        if (save) {
          savedIP = ip;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(kIpKey, ip);
        }
        _notify(true);
        _connectWs(ip);
        return true;
      }
    } catch (_) {}
    return false;
  }

  Future<String?> _getLocalIP() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!addr.isLoopback && !ip.startsWith('169.254') && !ip.startsWith('127.')) {
            return ip;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _scan() async {
    isScanning = true;
    _notify(isConnected);
    try {
      String? ip = await NetworkInfo().getWifiIP();
      if (ip == null || ip.isEmpty) ip = await _getLocalIP();
      if (ip == null || ip.isEmpty) { isScanning = false; _notify(isConnected); return; }
      final lastDot = ip.lastIndexOf('.');
      if (lastDot == -1) { isScanning = false; _notify(isConnected); return; }
      final sub = ip.substring(0, lastDot);
      final futures = <Future>[];
      for (int i = 1; i < 255; i++) futures.add(_probe('$sub.$i'));
      await Future.wait(futures);
    } catch (_) {}
    isScanning = false;
    _notify(isConnected);
  }

  Future<void> _probe(String ip) async {
    if (isConnected) return;
    try {
      final res = await Dio().post(
        'http://$ip:$kServerPort/connect',
        data: jsonEncode({'ip': ip}),
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(milliseconds: 1200),
          receiveTimeout: const Duration(milliseconds: 1200),
        ),
      );
      if (res.data.toString().trim() == 'MATCHED' && !isConnected) await handshake(ip);
    } catch (_) {}
  }

  void _connectWs(String ip) async {
    try {
      await _ws?.sink.close();
      _ws = WebSocketChannel.connect(Uri.parse('ws://$ip:$kWsPort'));
      _ws!.stream.listen(
        (data) {
          isWsConnected = true;
          try {
            final json = jsonDecode(data as String) as Map<String, dynamic>;
            _messageController.add(json);
          } catch (_) {}
        },
        onDone:  () { isWsConnected = false; _notify(false); },
        onError: (_) { isWsConnected = false; _notify(false); },
      );
      isWsConnected = true;
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(const Duration(seconds: 5), (_) => send({'type': 'ping'}));
    } catch (_) { isWsConnected = false; }
  }

  void send(Map<String, dynamic> data) {
    if (_ws != null && isWsConnected) {
      try { _ws!.sink.add(jsonEncode(data)); } catch (_) {}
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _ws?.sink.close();
    _messageController.close();
  }
}

// ─────────────────────────── MAIN ───────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await ScreenOrientationController.instance.init();
  await DexyLink.instance.init();
  runApp(const DexyApp());
}

class DexyApp extends StatelessWidget {
  const DexyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Dexy',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      primaryColor: C.accent,
      scaffoldBackgroundColor: Colors.black,
      colorScheme: const ColorScheme.dark(
          primary: C.accent, secondary: C.accent, surface: Color(0xFF111111)),
      textTheme: GoogleFonts.montserratTextTheme(ThemeData.dark().textTheme),
      useMaterial3: true,
    ),
    home: const SplashScreen(),
  );
}

// ─────────────────────────── SPLASH ───────────────────────────
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashState();
}

class _SplashState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale, _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(milliseconds: 1800), vsync: this);
    _scale = Tween<double>(begin: 0.4, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0, 0.5)));
    _ctrl.forward();
    Timer(const Duration(milliseconds: 2800), () {
      if (mounted)
        Navigator.of(context).pushReplacement(PageRouteBuilder(
          transitionDuration: const Duration(milliseconds: 600),
          pageBuilder: (_, __, ___) => const HomeScreen(),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeInOut), child: child),
        ));
    });
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(children: [
      Positioned.fill(child: _StarField()),
      Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        FadeTransition(
          opacity: _fade,
          child: ScaleTransition(
            scale: _scale,
            child: Image.asset('assets/logowithname.png', width: 260),
          ),
        ),
        const SizedBox(height: 50),
        FadeTransition(
          opacity: _fade,
          child: SizedBox(
            width: 36, height: 36,
            child: CircularProgressIndicator(
              color: Colors.white.withOpacity(0.5),
              strokeWidth: 2,
              backgroundColor: Colors.white.withOpacity(0.07),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FadeTransition(
          opacity: _fade,
          child: Text('INITIALIZING...',
            style: GoogleFonts.montserrat(
              color: Colors.white.withOpacity(0.25),
              fontSize: 10, letterSpacing: 4, fontWeight: FontWeight.w600)),
        ),
      ])),
    ]),
  );
}

// ─────────────────────────── STAR FIELD ───────────────────────────
class _StarField extends StatefulWidget {
  @override
  State<_StarField> createState() => _StarFieldState();
}

class _StarFieldState extends State<_StarField>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        duration: const Duration(seconds: 8), vsync: this)..repeat();
  }
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(animation: _ctrl,
          builder: (_, __) => CustomPaint(painter: _StarPainter(_ctrl.value)));
}

class _StarPainter extends CustomPainter {
  final double t;
  _StarPainter(this.t);
  static final _rng = Random(42);
  static final stars =
      List.generate(70, (_) => Offset(_rng.nextDouble(), _rng.nextDouble()));
  @override
  void paint(Canvas canvas, Size size) {
    for (int i = 0; i < stars.length; i++) {
      final opacity = (0.15 + 0.45 *
          ((sin((t * 2 * pi) + i * 0.7) + 1) / 2)).clamp(0.05, 0.6);
      canvas.drawCircle(
        Offset(stars[i].dx * size.width, stars[i].dy * size.height),
        (i % 3 == 0) ? 1.4 : 0.9,
        Paint()..color = Colors.white.withOpacity(opacity.toDouble()),
      );
    }
  }
  @override
  bool shouldRepaint(_StarPainter o) => o.t != t;
}

// ─────────────────────────── CONN CHIP ───────────────────────────
class ConnChip extends StatefulWidget {
  final VoidCallback? onTap;
  const ConnChip({super.key, this.onTap});
  @override
  State<ConnChip> createState() => _ConnChipState();
}

class _ConnChipState extends State<ConnChip> {
  bool _c = false;
  void _update(bool c) { if (mounted) setState(() => _c = c); }
  @override
  void initState() {
    super.initState();
    _c = DexyLink.instance.isConnected;
    DexyLink.instance.addListener(_update);
  }
  @override
  void dispose() { DexyLink.instance.removeListener(_update); super.dispose(); }
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: widget.onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.06),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(
          color: Colors.white.withOpacity(_c ? 0.35 : 0.12),
          width: 1.5,
        ),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _c ? const Color(0xFF4ADE80) : Colors.redAccent,
            boxShadow: [BoxShadow(
              color: (_c ? const Color(0xFF4ADE80) : Colors.redAccent).withOpacity(0.6),
              blurRadius: 8)],
          ),
        ),
        const SizedBox(width: 8),
        Text(
          _c
              ? (DexyLink.instance.isWsConnected ? 'SYNCED' : 'CONNECTED')
              : (DexyLink.instance.isScanning ? 'SEARCHING...' : 'NOT CONNECTED'),
          style: GoogleFonts.montserrat(
            fontSize: 8, fontWeight: FontWeight.w700,
            color: Colors.white.withOpacity(0.6), letterSpacing: 1.5),
        ),
        const SizedBox(width: 8),
        Icon(
          _c ? Icons.link_rounded : Icons.wifi_find_rounded,
          size: 14,
          color: C.accent,
        ),
      ]),
    ),
  );
}

class _RotateChip extends StatefulWidget {
  const _RotateChip();
  @override
  State<_RotateChip> createState() => _RotateChipState();
}

class _RotateChipState extends State<_RotateChip> {
  @override
  void initState() {
    super.initState();
    ScreenOrientationController.instance.addListener(_onChange);
  }

  @override
  void dispose() {
    ScreenOrientationController.instance.removeListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = ScreenOrientationController.instance;
    return GestureDetector(
      onTap: () => ctrl.cycle(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.06),
          borderRadius: BorderRadius.circular(30),
          border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.5),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.screen_rotation_rounded, size: 16, color: C.accent),
          const SizedBox(width: 8),
          Text(
            ctrl.label,
            style: GoogleFonts.montserrat(
              fontSize: 8,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.6),
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 6),
          Icon(Icons.rotate_90_degrees_cw_rounded,
              size: 14, color: Colors.white.withOpacity(0.45)),
        ]),
      ),
    );
  }
}

// ─────────────────────────── HOME SCREEN ───────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeState();
}

class _HomeState extends State<HomeScreen> with TickerProviderStateMixin {
  late AnimationController _gridCtrl;
  late AnimationController _bgZoomCtrl;
  late Animation<double> _bgZoom;

  final List<AnimationController> _btnCtrls = [];
  final List<Animation<double>> _btnFades  = [];

  // Button data: icon, label, enabled flag
  static const _btnData = [
    (Icons.photo_library_rounded,    'GALLERY',     true),
    (Icons.slow_motion_video_rounded,'WALKTHROUGH', true),
    (Icons.layers_rounded,           'PLANS',       true),
    (Icons.menu_book_rounded,        'BROCHURE',    true),
    (Icons.flight_rounded,           'DRONE',       true),
    (Icons.construction_rounded,     'CURRENT DEV', true),
  ];

  @override
  void initState() {
    super.initState();
    _gridCtrl =
        AnimationController(duration: const Duration(seconds: 14), vsync: this)
          ..repeat();

    _bgZoomCtrl = AnimationController(
        duration: const Duration(seconds: 12), vsync: this)
      ..repeat(reverse: true);
    _bgZoom = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _bgZoomCtrl, curve: Curves.easeInOut));

    for (int i = 0; i < 6; i++) {
      final c = AnimationController(
          duration: Duration(milliseconds: 550 + i * 100), vsync: this);
      _btnCtrls.add(c);
      _btnFades.add(Tween<double>(begin: 0, end: 1)
          .animate(CurvedAnimation(parent: c, curve: Curves.easeOut)));
      Future.delayed(Duration(milliseconds: 250 + i * 110),
          () { if (mounted) c.forward(); });
    }
  }

  @override
  void dispose() {
    _gridCtrl.dispose();
    _bgZoomCtrl.dispose();
    for (final c in _btnCtrls) c.dispose();
    super.dispose();
  }

  void _go(Widget page) => Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 450),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, a, __, child) {
      final slide = Tween<Offset>(begin: const Offset(0.04, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic));
      return FadeTransition(
          opacity: a, child: SlideTransition(position: slide, child: child));
    },
  ));

  void _showManual() {
    final ctrl = TextEditingController(text: DexyLink.instance.savedIP ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0E0E0E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: Colors.white.withOpacity(0.15), width: 1.5),
        ),
        title: Text('Manual Connect',
            style: GoogleFonts.montserrat(
                color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
        content: TextField(
          controller: ctrl,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            hintText: '192.168.x.x',
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.15))),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.white.withOpacity(0.5), width: 2)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 13))),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              final ip = ctrl.text.trim();
              if (ip.isNotEmpty) DexyLink.instance.handshake(ip);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white.withOpacity(0.12),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(color: Colors.white.withOpacity(0.3))),
            ),
            child: Text('Connect', style: GoogleFonts.montserrat(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sz = MediaQuery.of(context).size;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        Positioned.fill(
          child: AnimatedBuilder(
            animation: _bgZoomCtrl,
            builder: (_, __) => Transform.scale(
              scale: _bgZoom.value,
              child: Image.asset(
                'assets/background/jensenartofficial-big-data-7644533.jpg',
                fit: BoxFit.cover,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Container(color: Colors.black.withOpacity(0.7)),
        ),

        Positioned.fill(child: AnimatedBuilder(
          animation: _gridCtrl,
          builder: (_, __) => CustomPaint(
              painter: _GridPainter(_gridCtrl.value)),
        )),
        Positioned.fill(child: _StarField()),

        const Positioned(top: 0, left: 0,  child: _CornerDecor(flip: false)),
        const Positioned(top: 0, right: 0, child: _CornerDecor(flip: true)),

        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.asset('assets/logowithname.png', height: sz.height * 0.27),
          const SizedBox(height: 12),
          SizedBox(height: sz.height * 0.06),

          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (int i = 0; i < 6; i++) ...[
              if (i > 0) SizedBox(width: sz.width * 0.022),
              FadeTransition(
                opacity: _btnFades[i],
                child: _GlassBtn(
                  icon:  _btnData[i].$1,
                  label: _btnData[i].$2,
                  enabled: _btnData[i].$3,
                  onTap: () {
                    final pages = [
                      const GalleryPage(),
                      const WalkthroughPage(),
                      const PlansPage(),
                      const BrochurePage(),
                      const DronshootPage(),
                      const DevelopmentPage(),
                    ];
                    _go(pages[i]);
                  },
                ),
              ),
            ],
          ]),
        ])),

        Positioned(top: 20, right: 24, child: ConnChip(onTap: _showManual)),
        const Positioned(top: 20, left: 24, child: _RotateChip()),

        Positioned(bottom: 12, left: 0, right: 0, child: Center(
          child: Column(
            children: [
              const SizedBox(height: 4),
              Text('Powered by The DEX Company',
                  style: GoogleFonts.montserrat(
                      fontSize: 11,
                      color: C.accent,
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        )),
      ]),
    );
  }
}

// ─────────────────────────── WHITE GLASS 3-D BUTTON ───────────────────────────
class _GlassBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  const _GlassBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  @override
  State<_GlassBtn> createState() => _GlassBtnState();
}

class _GlassBtnState extends State<_GlassBtn>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _scale;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        duration: const Duration(milliseconds: 110), vsync: this);
    _scale = Tween<double>(begin: 1.0, end: 0.90)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeOut));
  }

  @override
  void dispose() { _c.dispose(); super.dispose(); }

  void _handleTapDown(TapDownDetails _) {
    if (!widget.enabled) return;
    _c.forward();
    setState(() => _pressed = true);
  }

  void _handleTapUp(TapUpDetails _) {
    if (!widget.enabled) return;
    _c.reverse();
    setState(() => _pressed = false);
    widget.onTap();
  }

  void _handleTapCancel() {
    if (!widget.enabled) return;
    _c.reverse();
    setState(() => _pressed = false);
  }

  @override
  Widget build(BuildContext context) {
    final sz   = MediaQuery.of(context).size;
    final size = sz.height * 0.145;
    final isEnabled = widget.enabled;
    final opacity = isEnabled ? 1.0 : 0.4;

    return GestureDetector(
      onTapDown: _handleTapDown,
      onTapUp: _handleTapUp,
      onTapCancel: _handleTapCancel,
      child: ScaleTransition(
        scale: _scale,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            width: size, height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.35, -0.4),
                radius: 1.0,
                colors: _pressed && isEnabled
                    ? [
                        Colors.white.withOpacity(0.28),
                        Colors.white.withOpacity(0.10),
                        Colors.black.withOpacity(0.55),
                      ]
                    : [
                        Colors.white.withOpacity(0.18 * opacity),
                        Colors.white.withOpacity(0.06 * opacity),
                        Colors.black.withOpacity(0.70 * opacity),
                      ],
              ),
              border: Border.all(
                color: Colors.white
                    .withOpacity((_pressed && isEnabled) ? 0.70 : 0.35 * opacity),
                width: (_pressed && isEnabled) ? 2.0 : 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.white
                      .withOpacity((_pressed && isEnabled) ? 0.22 : 0.10 * opacity),
                  blurRadius: (_pressed && isEnabled) ? 28 : 16,
                  spreadRadius: (_pressed && isEnabled) ? 2 : 0,
                ),
                BoxShadow(
                  color: Colors.black.withOpacity(0.55 * opacity),
                  blurRadius: 10,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Icon(widget.icon,
                color: C.accent.withOpacity((_pressed && isEnabled) ? 1.0 : 0.85 * opacity),
                size: size * 0.36),
          ),
          const SizedBox(height: 10),
          AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 140),
            style: GoogleFonts.montserrat(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5, // same as "Powered by The DEX Company"
              color: Colors.white.withOpacity((_pressed && isEnabled) ? 0.95 : 0.65 * opacity),
            ),
            child: Text(widget.label),
          ),
        ]),
      ),
    );
  }
}

// ─────────────────────────── CORNER DECORATION ───────────────────────────
class _CornerDecor extends StatelessWidget {
  final bool flip;
  const _CornerDecor({required this.flip});
  @override
  Widget build(BuildContext context) => Transform.scale(
    scaleX: flip ? -1 : 1,
    child: SizedBox(
      width: 90, height: 90,
      child: CustomPaint(painter: _CornerPainter()),
    ),
  );
}

class _CornerPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size sz) {
    final p1 = Paint()
      ..color = Colors.white.withOpacity(0.22)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 28), const Offset(0, 0), p1);
    canvas.drawLine(const Offset(0, 0),  const Offset(28, 0), p1);
    final p2 = Paint()
      ..color = Colors.white.withOpacity(0.08)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 55), const Offset(0, 33), p2);
    canvas.drawLine(const Offset(33, 0), const Offset(55, 0), p2);
  }
  @override
  bool shouldRepaint(_) => false;
}

// ─────────────────────────── GRID PAINTER ───────────────────────────
class _GridPainter extends CustomPainter {
  final double t;
  _GridPainter(this.t);
  @override
  void paint(Canvas canvas, Size size) {
    const spacing = 72.0;
    final p = Paint()..strokeWidth = 0.4;
    for (double x = 0; x < size.width; x += spacing) {
      p.color = Colors.white
          .withOpacity(0.025 + 0.012 * sin(t * 2 * pi + x / 90));
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    }
    for (double y = 0; y < size.height; y += spacing) {
      p.color = Colors.white
          .withOpacity(0.025 + 0.012 * sin(t * 2 * pi + y / 90));
      canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    }
  }
  @override
  bool shouldRepaint(_GridPainter o) => o.t != t;
}

// ─────────────────────────── NAV BUTTON ───────────────────────────
class _NavBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? label;
  const _NavBtn({required this.icon, required this.onTap, this.label});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: label != null
          ? const EdgeInsets.symmetric(horizontal: 20, vertical: 14)
          : const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(label != null ? 30 : 50),
        color: Colors.white.withOpacity(0.07),
        border: Border.all(
            color: Colors.white.withOpacity(0.25), width: 1.5),
      ),
      child: label != null
          ? Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: C.accent, size: 28),
              const SizedBox(width: 8),
              Text(label!,
                  style: GoogleFonts.montserrat(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2)),
            ])
          : Icon(icon, color: C.accent, size: 32),
    ),
  );
}

// ─────────────────────────── SHELL ───────────────────────────
class _Shell extends StatelessWidget {
  final Widget child;
  final String screen;
  const _Shell({required this.child, required this.screen});
  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    body: Stack(children: [
      Positioned.fill(child: child),
      Positioned(top: 20, left: 20, child: _NavBtn(
        icon: Icons.arrow_back_ios_new_rounded,
        onTap: () {
          DexyLink.instance.send({'type': 'navigate', 'screen': 'home'});
          Navigator.of(context).pop();
        },
      )),
      Positioned(top: 20, right: 20, child: _NavBtn(
        icon: Icons.home_rounded,
        onTap: () {
          DexyLink.instance.send({'type': 'navigate', 'screen': 'home'});
          Navigator.of(context).popUntil((r) => r.isFirst);
        },
      )),
    ]),
  );
}

// ─────────────────────────── DOTS ───────────────────────────
class _Dots extends StatelessWidget {
  final int count, cur;
  const _Dots({required this.count, required this.cur});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: List.generate(count, (i) {
      final act = i == cur;
      return AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        margin: const EdgeInsets.symmetric(horizontal: 5),
        width: act ? 22 : 7, height: 7,
        decoration: BoxDecoration(
          color: act ? C.accent : Colors.white.withOpacity(0.25),
          borderRadius: BorderRadius.circular(4),
          boxShadow: act
              ? [BoxShadow(color: C.accent.withOpacity(0.4), blurRadius: 8)]
              : [],
        ),
      );
    }),
  );
}

// ─────────────────────────── LABEL ───────────────────────────
class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black.withOpacity(0.65),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(
          color: C.accent.withOpacity(0.55), width: 1.5),
      boxShadow: [
        BoxShadow(color: C.accent.withOpacity(0.12), blurRadius: 12)
      ],
    ),
    child: Text(text,
        style: GoogleFonts.montserrat(
            color: C.accent,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 2.5)),
  );
}

// ─────────────────────────── THUMBNAIL STRIP (between prev / next) ───────────
class _ThumbnailStrip extends StatefulWidget {
  final List<String> images;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final double thumbSize;

  const _ThumbnailStrip({
    required this.images,
    required this.selectedIndex,
    required this.onSelect,
    this.thumbSize = 64,
  });

  @override
  State<_ThumbnailStrip> createState() => _ThumbnailStripState();
}

class _ThumbnailStripState extends State<_ThumbnailStrip> {
  late final ScrollController _scroll;
  static const double _spacing = 8;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(_ThumbnailStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _scrollToSelected();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_scroll.hasClients) return;
    final target = widget.selectedIndex * (widget.thumbSize + _spacing) - 40;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: widget.images.length,
      separatorBuilder: (_, __) => const SizedBox(width: _spacing),
      itemBuilder: (_, i) {
        final selected = i == widget.selectedIndex;
        return GestureDetector(
          onTap: () => widget.onSelect(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: widget.thumbSize,
            height: widget.thumbSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? C.accent : Colors.white.withOpacity(0.18),
                width: selected ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: C.accent.withOpacity(0.35), blurRadius: 8)]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.asset(widget.images[i],
                  fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────── PDF THUMBNAIL STRIP (brochure) ──────────────────
class _PdfThumbnailStrip extends StatefulWidget {
  final int totalPages;
  final int selectedIndex;
  final Map<int, Uint8List> pageCache;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onNeedPage;
  final double thumbSize;

  const _PdfThumbnailStrip({
    required this.totalPages,
    required this.selectedIndex,
    required this.pageCache,
    required this.onSelect,
    required this.onNeedPage,
    this.thumbSize = 64,
  });

  @override
  State<_PdfThumbnailStrip> createState() => _PdfThumbnailStripState();
}

class _PdfThumbnailStripState extends State<_PdfThumbnailStrip> {
  late final ScrollController _scroll;
  static const double _spacing = 8;

  @override
  void initState() {
    super.initState();
    _scroll = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToSelected());
  }

  @override
  void didUpdateWidget(_PdfThumbnailStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) {
      _scrollToSelected();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToSelected() {
    if (!_scroll.hasClients) return;
    final target = widget.selectedIndex * (widget.thumbSize + _spacing) - 40;
    _scroll.animateTo(
      target.clamp(0.0, _scroll.position.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      itemCount: widget.totalPages,
      separatorBuilder: (_, __) => const SizedBox(width: _spacing),
      itemBuilder: (_, i) {
        final selected = i == widget.selectedIndex;
        final bytes = widget.pageCache[i];
        if (bytes == null) widget.onNeedPage(i);

        return GestureDetector(
          onTap: () => widget.onSelect(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: widget.thumbSize,
            height: widget.thumbSize,
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: selected ? C.accent : Colors.white.withOpacity(0.18),
                width: selected ? 2.5 : 1,
              ),
              boxShadow: selected
                  ? [BoxShadow(color: C.accent.withOpacity(0.35), blurRadius: 8)]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: bytes != null
                  ? Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true)
                  : Center(
                      child: Text('${i + 1}',
                          style: GoogleFonts.montserrat(
                            color: Colors.white30,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          )),
                    ),
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────── SHARED IMAGE BROWSER ───────────────────────────
class _ImageBrowserPage extends StatefulWidget {
  final String screen;
  final String scrollType;
  final String label;
  final List<String> images;

  const _ImageBrowserPage({
    required this.screen,
    required this.scrollType,
    required this.label,
    required this.images,
  });

  @override
  State<_ImageBrowserPage> createState() => _ImageBrowserPageState();
}

class _ImageBrowserPageState extends State<_ImageBrowserPage>
    with SingleTickerProviderStateMixin {
  final PageController _pg = PageController();
  final TransformationController _zoom = TransformationController();
  late AnimationController _zoomAnimCtrl;
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _doubleTapDetails;
  int _idx = 0;
  bool _isZoomed = false;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    DexyLink.instance.send({'type': 'navigate', 'screen': widget.screen});
    _zoomAnimCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      DexyScreenCache.precacheAssets(context, widget.images);
      _sendScroll(_idx);
    });
  }

  @override
  void dispose() {
    _pg.dispose();
    _zoom.dispose();
    _zoomAnimCtrl.dispose();
    super.dispose();
  }

  void _sendScroll(int i) {
    DexyLink.instance.send({'type': widget.scrollType, 'index': i});
  }

  void _goToIndex(int i) {
    if (i == _idx) return;
    _resetZoom();
    setState(() => _idx = i);
    _sendScroll(i);
    if (_pg.hasClients) {
      _pg.animateToPage(i,
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  void _animateZoomTo(Matrix4 target) {
    _zoomAnim?.removeListener(_onZoomTick);
    final begin = _zoom.value.clone();
    _zoomAnim = Matrix4Tween(begin: begin, end: target)
        .animate(CurvedAnimation(parent: _zoomAnimCtrl, curve: Curves.easeInOutCubic));
    _zoomAnim!.addListener(_onZoomTick);
    _zoomAnimCtrl.reset();
    _zoomAnimCtrl.forward();
  }

  void _onZoomTick() {
    if (_zoomAnim == null) return;
    _zoom.value = _zoomAnim!.value;
    final s = _zoom.value.getMaxScaleOnAxis();
    _currentScale = s;
    final z = s > 1.05;
    if (z != _isZoomed && mounted) setState(() => _isZoomed = z);
    DexyLink.instance.send({'type': 'zoom', 'scale': s,
      'dx': _zoom.value.entry(0, 3), 'dy': _zoom.value.entry(1, 3)});
  }

  void _resetZoom() => _animateZoomTo(Matrix4.identity());

  void _handleDoubleTap() {
    if (_currentScale > 1.05) {
      _animateZoomTo(Matrix4.identity());
    } else {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      const s = 2.5;
      final m = Matrix4.identity()
        ..translate(-pos.dx * (s - 1), -pos.dy * (s - 1))
        ..scale(s);
      _animateZoomTo(m);
    }
  }

  Widget _buildBody() {
    return Stack(children: [
      PageView.builder(
        controller: _pg,
        physics: _isZoomed
            ? const NeverScrollableScrollPhysics()
            : const BouncingScrollPhysics(),
        itemCount: widget.images.length,
        onPageChanged: (i) {
          _resetZoom();
          setState(() => _idx = i);
          _sendScroll(i);
        },
        itemBuilder: (_, i) {
          final img = Image.asset(widget.images[i],
              fit: BoxFit.cover,
              gaplessPlayback: true,
              width: double.infinity,
              height: double.infinity);
          if (i != _idx) return img;
          return GestureDetector(
            onDoubleTapDown: (d) => _doubleTapDetails = d,
            onDoubleTap: _handleDoubleTap,
            child: InteractiveViewer(
              transformationController: _zoom,
              minScale: 1.0,
              maxScale: 6.0,
              clipBehavior: Clip.hardEdge,
              onInteractionStart: (_) {
                _zoomAnimCtrl.stop();
                _zoomAnim?.removeListener(_onZoomTick);
              },
              onInteractionUpdate: (d) {
                final s = _zoom.value.getMaxScaleOnAxis();
                _currentScale = s;
                final z = s > 1.05;
                if (z != _isZoomed) setState(() => _isZoomed = z);
                DexyLink.instance.send({'type': 'zoom', 'scale': s,
                  'dx': _zoom.value.entry(0, 3), 'dy': _zoom.value.entry(1, 3)});
              },
              onInteractionEnd: (_) {
                if (_currentScale < 1.05) _animateZoomTo(Matrix4.identity());
              },
              child: img,
            ),
          );
        },
      ),
      Positioned(top: 20, left: 0, right: 0, child: Center(
          child: _Label('${widget.label}  ${_idx + 1} / ${widget.images.length}'))),
      Positioned(
        bottom: 20,
        left: 12,
        right: 12,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _NavBtn(
              icon: Icons.navigate_before_rounded,
              onTap: () {
                if (_idx > 0) _pg.previousPage(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeInOut);
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: SizedBox(
                height: 68,
                child: _ThumbnailStrip(
                  images: widget.images,
                  selectedIndex: _idx,
                  onSelect: _goToIndex,
                ),
              ),
            ),
            const SizedBox(width: 10),
            _NavBtn(
              icon: Icons.navigate_next_rounded,
              onTap: () {
                if (_idx < widget.images.length - 1) _pg.nextPage(
                    duration: const Duration(milliseconds: 350),
                    curve: Curves.easeInOut);
              },
            ),
          ],
        ),
      ),
      if (_isZoomed)
        Positioned(bottom: 96, right: 20,
          child: GestureDetector(
            onTap: _resetZoom,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.7),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: Colors.white.withOpacity(0.2))),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.zoom_out_rounded, color: C.accent, size: 16),
                const SizedBox(width: 6),
                Text('${_currentScale.toStringAsFixed(1)}x',
                    style: GoogleFonts.montserrat(
                        color: Colors.white.withOpacity(0.65),
                        fontSize: 8, fontWeight: FontWeight.w600)),
              ]),
            ),
          )),
    ]);
  }

  @override
  Widget build(BuildContext context) => _Shell(
    screen: widget.screen,
    child: _buildBody(),
  );
}

// ─────────────────────────── GALLERY PAGE ───────────────────────────
class GalleryPage extends StatelessWidget {
  const GalleryPage({super.key});
  @override
  Widget build(BuildContext context) => _ImageBrowserPage(
    screen: 'gallery',
    scrollType: 'gallery_scroll',
    label: 'GALLERY',
    images: kGalleryImages,
  );
}

// ─────────────────────────── PLANS PAGE ───────────────────────────
class PlansPage extends StatelessWidget {
  const PlansPage({super.key});
  @override
  Widget build(BuildContext context) => _ImageBrowserPage(
    screen: 'plans',
    scrollType: 'plans_scroll',
    label: 'PLANS',
    images: kPlansImages,
  );
}

// ─────────────────────────── ENHANCED VIDEO PAGE ───────────────────────────
class _VideoPage extends StatefulWidget {
  final List<String> videos;
  final String screenName;
  final String label;
  final bool showTopLabel;
  final bool showThumbnailBorder;
  final bool backgroundCover;  // new flag: true = cover, false = contain

  const _VideoPage({
    required this.videos,
    required this.screenName,
    required this.label,
    this.showTopLabel = true,
    this.showThumbnailBorder = true,
    this.backgroundCover = true,  // default to cover
  });

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  int _sel = 0;
  bool _playing = false;
  double _pos = 0, _dur = 0, _vol = 1.0;
  bool _seeking = false;

  final Map<String, Uint8List> _thumbs = {};
  final Map<String, String> _videoFilePaths = {};
  StreamSubscription? _statusSub;

  @override
  void initState() {
    super.initState();
    DexyLink.instance.send({'type': 'navigate', 'screen': widget.screenName});

    final cachedThumbs = DexyScreenCache.videoThumbs[widget.screenName];
    final cachedPaths = DexyScreenCache.videoPaths[widget.screenName];
    if (cachedThumbs != null) {
      _thumbs.addAll(cachedThumbs);
      if (cachedPaths != null) _videoFilePaths.addAll(cachedPaths);
    } else {
      _extractThenGenThumbs();
    }

    _loadVideo(0);

    _statusSub = DexyLink.instance.onMessage.listen((msg) {
      if (msg['type'] == 'video_status' && msg['screen'] == widget.screenName) {
        setState(() {
          final newIdx = msg['index'] as int?;
          if (newIdx != null && newIdx != _sel) {
            _sel = newIdx;
          }
          if (!_seeking) {
            _pos = (msg['position'] as num?)?.toDouble() ?? _pos;
          }
          _dur = (msg['duration'] as num?)?.toDouble() ?? _dur;
          _playing = msg['playing'] as bool? ?? _playing;
        });
      }
    });
  }

  Future<void> _extractThenGenThumbs() async {
    for (final v in widget.videos) {
      try {
        await _extractAssetToFile(v);
        debugPrint('[Sender] Extracted: $v');
      } catch (e) {
        debugPrint('[Sender] Extract failed for $v: $e');
      }
    }
    await _genThumbs();
    DexyScreenCache.videoThumbs[widget.screenName] = Map.from(_thumbs);
    DexyScreenCache.videoPaths[widget.screenName] = Map.from(_videoFilePaths);
  }

  Future<void> _genThumbs() async {
    final appDir = await getApplicationDocumentsDirectory();
    final td = Directory(p.join(appDir.path, 'th_${widget.screenName}'));
    if (!await td.exists()) await td.create(recursive: true);
    for (int i = 0; i < widget.videos.length; i++) {
      final vp   = widget.videos[i];
      final name = p.basenameWithoutExtension(vp);
      final f    = File(p.join(td.path, '$name.jpg'));
      if (await f.exists()) {
        if (mounted) setState(() => _thumbs[vp] = f.readAsBytesSync());
        continue;
      }
      try {
        final videoPath = _videoFilePaths[vp];
        if (videoPath == null || !await File(videoPath).exists()) {
          debugPrint('[Sender] Thumb skip (not extracted yet): $vp');
          continue;
        }
        final th = await VideoThumbnail.thumbnailData(
            video: videoPath,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 400, quality: 75, timeMs: 1000);
        if (th != null) {
          await f.writeAsBytes(th);
          if (mounted) setState(() => _thumbs[vp] = th);
          debugPrint('[Sender] Thumb generated: $name.jpg');
        }
      } catch (e) {
        debugPrint('[Sender] Thumb gen failed for $vp: $e');
      }
    }
  }

  Future<String> _extractAssetToFile(String assetPath) async {
    if (_videoFilePaths.containsKey(assetPath)) {
      final cached = _videoFilePaths[assetPath]!;
      if (await File(cached).exists()) return cached;
    }
    final tmpDir  = await getTemporaryDirectory();
    final outFile = File(p.join(tmpDir.path,
        'dexy_vid_${widget.screenName}_${p.basename(assetPath)}'));
    if (!await outFile.exists()) {
      final data = await rootBundle.load(assetPath);
      await outFile.writeAsBytes(data.buffer.asUint8List());
    }
    _videoFilePaths[assetPath] = outFile.path;
    return outFile.path;
  }

  Future<void> _loadVideo(int idx) async {
    setState(() { _sel = idx; _pos = 0; _dur = 0; _playing = false; });
    // Let Windows mount video surface before opening large 4K file.
    await Future.delayed(const Duration(milliseconds: 250));
    DexyLink.instance.send(
        {'type': 'video_select', 'screen': widget.screenName, 'index': idx});
    if (mounted) setState(() => _playing = true);
  }

  void _togglePlay() {
    final action = _playing ? 'pause' : 'play';
    DexyLink.instance.send({'type': 'video_control', 'action': action});
    setState(() => _playing = !_playing);
  }

  void _skip(int sec) {
    final newPosMs = (_pos + sec * 1000.0).clamp(0.0, _dur > 0 ? _dur : double.infinity);
    setState(() => _pos = newPosMs);
    DexyLink.instance.send({'type': 'video_control', 'action': 'seek',
      'value': newPosMs / 1000.0});
  }

  void _seekEnd(double v) {
    _seeking = false;
    DexyLink.instance.send({'type': 'video_control', 'action': 'seek',
      'value': v / 1000.0});
  }

  void _setVol(double v) {
    setState(() => _vol = v);
    DexyLink.instance.send({'type': 'video_control', 'action': 'volume', 'value': v});
  }

  String _fmt(double ms) {
    final d = Duration(milliseconds: ms.toInt());
    return '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  SliderThemeData get _sliderTheme => SliderTheme.of(context).copyWith(
    activeTrackColor:   C.accent,
    inactiveTrackColor: Colors.white.withOpacity(0.2),
    thumbColor:         C.accent,
    thumbShape:         const RoundSliderThumbShape(enabledThumbRadius: 10),
    trackHeight:        4,
    overlayColor:       C.accent.withOpacity(0.25),
    overlayShape:       const RoundSliderOverlayShape(overlayRadius: 20),
  );

  SliderThemeData get _volTheme => SliderTheme.of(context).copyWith(
    activeTrackColor:   C.accent,
    inactiveTrackColor: Colors.white.withOpacity(0.15),
    thumbColor:         C.accent,
    thumbShape:         const RoundSliderThumbShape(enabledThumbRadius: 6),
    trackHeight:        3,
    overlayShape:       SliderComponentShape.noOverlay,
  );

  @override
  Widget build(BuildContext context) {
    final sz     = MediaQuery.of(context).size;
    final thumbW = sz.width * 0.16;
    return _Shell(
      screen: widget.screenName,
      child: Stack(children: [
        // ── THUMBNAIL BACKGROUND ──
        Positioned.fill(
          child: Builder(builder: (ctx) {
            final thumb = _thumbs[widget.videos[_sel]];
            if (thumb != null) {
              return Stack(children: [
                Positioned.fill(
                  child: Image.memory(
                    thumb,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    width: double.infinity,
                    height: double.infinity,
                  ),
                ),
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(0.4),
                  ),
                ),
                Positioned(
                  top: 0, bottom: 0, right: 0, left: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _playing ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 400),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.7),
                          borderRadius: BorderRadius.circular(40),
                          border: Border.all(color: C.accent.withOpacity(0.7), width: 2),
                          boxShadow: [
                            BoxShadow(color: C.accent.withOpacity(0.3), blurRadius: 20)
                          ],
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFF4ADE80),
                              boxShadow: [BoxShadow(color: const Color(0xFF4ADE80).withOpacity(0.6), blurRadius: 10)],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text('PLAYING ON RECEIVER',
                              style: GoogleFonts.montserrat(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 2.5)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ]);
            }
            return Container(
              color: Colors.black,
              child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: C.accent, strokeWidth: 3),
                const SizedBox(height: 20),
                Text('Loading ${widget.label}...',
                    style: GoogleFonts.montserrat(
                        color: C.accent.withOpacity(0.8),
                        fontSize: 11, letterSpacing: 2)),
              ])),
            );
          }),
        ),

        // ── THUMBNAIL STRIP (left) ──
        Positioned(
          left: 68, top: 70, bottom: 70, width: thumbW,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Show the label and border only if allowed
              if (widget.showTopLabel) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(
                            color: C.accent.withOpacity(0.5),
                            width: 2)),
                  ),
                  child: Text(widget.label,
                      style: GoogleFonts.montserrat(
                          color: C.accent,
                          fontSize: 9,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.5),
                      textAlign: TextAlign.center),
                ),
                const SizedBox(height: 8),
              ],
              // Add a small top gap when the top label is hidden
              if (!widget.showTopLabel) const SizedBox(height: 10),
              Expanded(
                child: ListView.builder(
                  padding: EdgeInsets.only(bottom: 8), // keep bottom padding
                  itemCount: widget.videos.length,
                  itemBuilder: (ctx, i) {
                    final act   = i == _sel;
                    final thumb = _thumbs[widget.videos[i]];
                    return GestureDetector(
                      onTap: () => _loadVideo(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        height: act ? 90 : 60,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: act
                                ? C.accent
                                : Colors.white.withOpacity(0.2),
                            width: act ? 3 : 1.5,
                          ),
                          boxShadow: act
                              ? [BoxShadow(
                                  color: C.accent.withOpacity(0.4),
                                  blurRadius: 18,
                                  spreadRadius: 2)]
                              : [],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: thumb != null
                              ? Image.memory(thumb,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  width: double.infinity,
                                  height: double.infinity)
                              : Container(
                                  color: Colors.white.withOpacity(0.05),
                                  child: Icon(
                                      Icons.play_circle_outline,
                                      color: act
                                          ? C.accent
                                          : Colors.white24,
                                      size: 32)),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),

        // ── TOP LABEL (only if enabled) ──
        if (widget.showTopLabel)
          Positioned(top: 20, left: 0, right: 0,
            child: Center(child: _Label(widget.label))),

        // ── BOTTOM CONTROLS ──
        Positioned(
          bottom: 0, left: 0, right: 0,
          child: Container(
            padding: EdgeInsets.fromLTRB(thumbW + 88, 20, 26, 24),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end:   Alignment.topCenter,
                colors: [
                  Colors.black.withOpacity(0.8),
                  Colors.transparent,
                ],
              ),
              border: Border(
                  top: BorderSide(
                      color: C.accent.withOpacity(0.3), width: 1.5)),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // ── Seek bar ──
              Row(children: [
                Text(_fmt(_pos),
                    style: GoogleFonts.montserrat(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                const SizedBox(width: 12),
                Expanded(child: SliderTheme(
                  data: _sliderTheme,
                  child: Slider(
                    value: _dur > 0 ? _pos.clamp(0, _dur) : 0,
                    min: 0, max: _dur > 0 ? _dur : 1,
                    onChangeStart: (v) {
                      _seeking = true;
                      setState(() => _pos = v);
                    },
                    onChanged: (v) => setState(() => _pos = v),
                    onChangeEnd:  _seekEnd,
                  ),
                )),
                const SizedBox(width: 12),
                Text(_fmt(_dur),
                    style: GoogleFonts.montserrat(
                        color: Colors.white.withOpacity(0.7),
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
              ]),
              const SizedBox(height: 12),

              // ── Controls row ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.volume_down_rounded,
                      color: C.accent, size: 24),
                  SizedBox(width: 120,
                    child: SliderTheme(
                      data: _volTheme,
                      child: Slider(
                          value: _vol, min: 0, max: 1,
                          onChanged: _setVol),
                    ),
                  ),
                  Icon(Icons.volume_up_rounded,
                      color: C.accent, size: 24),

                  const SizedBox(width: 30),

                  _CtrlBtn(
                      icon: Icons.replay_30_rounded, size: 44,
                      onTap: () => _skip(-30)),
                  const SizedBox(width: 10),
                  _CtrlBtn(
                      icon: Icons.replay_10_rounded, size: 42,
                      onTap: () => _skip(-10)),
                  const SizedBox(width: 20),

                  GestureDetector(
                    onTap: _togglePlay,
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.6),
                        border: Border.all(
                            color: C.accent, width: 3),
                        boxShadow: [
                          BoxShadow(
                              color: C.accent.withOpacity(0.4),
                              blurRadius: 28,
                              spreadRadius: 2),
                        ],
                      ),
                      child: Icon(
                        _playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        color: C.accent, size: 60),
                    ),
                  ),

                  const SizedBox(width: 20),
                  _CtrlBtn(
                      icon: Icons.forward_10_rounded, size: 42,
                      onTap: () => _skip(10)),
                  const SizedBox(width: 10),
                  _CtrlBtn(
                      icon: Icons.forward_30_rounded, size: 44,
                      onTap: () => _skip(30)),
                ],
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

// ─────────────────────────── CONTROL BUTTON ───────────────────────────
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final double size;
  final VoidCallback onTap;
  const _CtrlBtn({required this.icon, required this.size, required this.onTap});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: C.accent.withOpacity(0.5), width: 1.5),
        color: Colors.black.withOpacity(0.4),
      ),
      child: Icon(icon, color: C.accent, size: size),
    ),
  );
}

// ─────────────────────────── WALKTHROUGH / DRONSHOOT ───────────────────────────
class WalkthroughPage extends StatelessWidget {
  const WalkthroughPage({super.key});
  @override
  Widget build(BuildContext context) => const _VideoPage(
      videos: kWalkthroughVideos,
      screenName: 'walkthrough',
      label: 'WALKTHROUGH',
      showTopLabel: false,
      showThumbnailBorder: false,
      backgroundCover: true,
    );
}

class DronshootPage extends StatelessWidget {
  const DronshootPage({super.key});
  @override
  Widget build(BuildContext context) => const _VideoPage(
      videos: kDronshootVideos,
      screenName: 'dronshoot',
      label: 'DRONE SHOOT',
      showTopLabel: false,
      showThumbnailBorder: false,
      backgroundCover: true,
    );
}

// ─────────────────────────── DEVELOPMENT PAGE ───────────────────────────
class DevelopmentPage extends StatelessWidget {
  const DevelopmentPage({super.key});
  @override
  Widget build(BuildContext context) => _ImageBrowserPage(
    screen: 'development',
    scrollType: 'dev_scroll',
    label: 'CURRENT DEV',
    images: kDevImages,
  );
}

// ─────────────────────────── BROCHURE PAGE ───────────────────────────
class BrochurePage extends StatefulWidget {
  const BrochurePage({super.key});
  @override
  State<BrochurePage> createState() => _BrochurePageState();
}

class _BrochurePageState extends State<BrochurePage> with SingleTickerProviderStateMixin {
  final PageController _pg = PageController();
  final TransformationController _zoom = TransformationController();
  late AnimationController _zoomAnimCtrl;
  Animation<Matrix4>? _zoomAnim;
  TapDownDetails? _doubleTapDetails;

  int _totalPages = DexyScreenCache.brochurePageCount;
  int _idx = 0;
  bool _isZoomed = false;
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    DexyLink.instance.send({'type': 'navigate', 'screen': 'brochure'});
    _zoomAnimCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 380));
    _initPdf();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_totalPages > 0) {
        DexyLink.instance.send({'type': 'brochure_scroll', 'index': _idx});
      }
    });
  }

  Future<void> _initPdf() async {
    try {
      await DexyScreenCache.ensureBrochureLoaded();
      if (!mounted) return;
      final count = DexyScreenCache.brochurePageCount;
      if (count != _totalPages) setState(() => _totalPages = count);
      if (DexyScreenCache.brochurePages.isEmpty) {
        await _loadPage(0);
        await _loadPage(1);
      }
    } catch (e) {
      debugPrint('Error loading PDF: $e');
    }
  }

  Future<void> _loadPage(int pageIdx) async {
    if (DexyScreenCache.brochurePages.containsKey(pageIdx)) {
      if (mounted) setState(() {});
      return;
    }
    await DexyScreenCache.loadBrochurePage(pageIdx);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _pg.dispose();
    _zoom.dispose();
    _zoomAnimCtrl.dispose();
    super.dispose();
  }

  void _animateZoomTo(Matrix4 target) {
    _zoomAnim?.removeListener(_onZoomTick);
    final begin = _zoom.value.clone();
    _zoomAnim = Matrix4Tween(begin: begin, end: target)
        .animate(CurvedAnimation(parent: _zoomAnimCtrl, curve: Curves.easeInOutCubic));
    _zoomAnim!.addListener(_onZoomTick);
    _zoomAnimCtrl.reset();
    _zoomAnimCtrl.forward();
  }

  void _onZoomTick() {
    if (_zoomAnim == null) return;
    _zoom.value = _zoomAnim!.value;
    final s = _zoom.value.getMaxScaleOnAxis();
    _currentScale = s;
    final z = s > 1.05;
    if (z != _isZoomed && mounted) setState(() => _isZoomed = z);
    DexyLink.instance.send({'type': 'zoom', 'scale': s,
      'dx': _zoom.value.entry(0, 3), 'dy': _zoom.value.entry(1, 3)});
  }

  void _resetZoom() => _animateZoomTo(Matrix4.identity());

  void _handleDoubleTap() {
    if (_currentScale > 1.05) {
      _animateZoomTo(Matrix4.identity());
    } else {
      final pos = _doubleTapDetails?.localPosition ?? Offset.zero;
      const s = 2.5;
      final m = Matrix4.identity()
        ..translate(-pos.dx * (s - 1), -pos.dy * (s - 1))
        ..scale(s);
      _animateZoomTo(m);
    }
  }

  void _goToPage(int i) {
    if (i == _idx) return;
    _resetZoom();
    setState(() => _idx = i);
    DexyLink.instance.send({'type': 'brochure_scroll', 'index': i});
    _loadPage(i);
    if (i > 0) _loadPage(i - 1);
    if (i < _totalPages - 1) _loadPage(i + 1);
    if (_pg.hasClients) {
      _pg.animateToPage(i,
          duration: const Duration(milliseconds: 350), curve: Curves.easeInOut);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_totalPages == 0) {
      return _Shell(
        screen: 'brochure',
        child: const Center(child: CircularProgressIndicator(color: C.accent)),
      );
    }

    return _Shell(
      screen: 'brochure',
      child: Stack(children: [
        PageView.builder(
          controller: _pg,
          physics: _isZoomed
              ? const NeverScrollableScrollPhysics()
              : const BouncingScrollPhysics(),
          itemCount: _totalPages,
          onPageChanged: (i) {
            _resetZoom();
            setState(() => _idx = i);
            DexyLink.instance.send({'type': 'brochure_scroll', 'index': i});
            _loadPage(i);
            if (i > 0) _loadPage(i - 1);
            if (i < _totalPages - 1) _loadPage(i + 1);
          },
          itemBuilder: (_, i) {
            final bytes = DexyScreenCache.brochurePages[i];
            if (bytes == null) {
              _loadPage(i);
              return const Center(child: CircularProgressIndicator(color: C.accent));
            }
            final img = Container(
              color: Colors.black,
              child: Center(
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            );
            if (i != _idx) return img;
            return GestureDetector(
              onDoubleTapDown: (d) => _doubleTapDetails = d,
              onDoubleTap: _handleDoubleTap,
              child: InteractiveViewer(
                transformationController: _zoom,
                minScale: 1.0, maxScale: 6.0,
                clipBehavior: Clip.hardEdge,
                onInteractionStart: (_) {
                  _zoomAnimCtrl.stop();
                  _zoomAnim?.removeListener(_onZoomTick);
                },
                onInteractionUpdate: (d) {
                  final s = _zoom.value.getMaxScaleOnAxis();
                  _currentScale = s;
                  final z = s > 1.05;
                  if (z != _isZoomed) setState(() => _isZoomed = z);
                  DexyLink.instance.send({'type': 'zoom', 'scale': s,
                    'dx': _zoom.value.entry(0, 3), 'dy': _zoom.value.entry(1, 3)});
                },
                onInteractionEnd: (_) {
                  if (_currentScale < 1.05) _animateZoomTo(Matrix4.identity());
                },
                child: img,
              ),
            );
          },
        ),
        // ── Bottom nav: Prev · Thumbnails · Next ──
        Positioned(
          bottom: 20,
          left: 12,
          right: 12,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _NavBtn(
                icon: Icons.navigate_before_rounded,
                onTap: () {
                  if (_idx > 0) _pg.previousPage(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOut);
                },
              ),
              const SizedBox(width: 10),
              Expanded(
                child: SizedBox(
                  height: 68,
                  child: _PdfThumbnailStrip(
                    totalPages: _totalPages,
                    selectedIndex: _idx,
                    pageCache: DexyScreenCache.brochurePages,
                    onSelect: _goToPage,
                    onNeedPage: _loadPage,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              _NavBtn(
                icon: Icons.navigate_next_rounded,
                onTap: () {
                  if (_idx < _totalPages - 1) _pg.nextPage(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOut);
                },
              ),
            ],
          ),
        ),
        Positioned(top: 20, left: 0, right: 0,
            child: Center(child: _Label('BROCHURE  ${_idx + 1} / $_totalPages'))),
        if (_isZoomed)
          Positioned(bottom: 96, right: 20,
            child: GestureDetector(
              onTap: _resetZoom,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.7),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.2))),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.zoom_out_rounded, color: C.accent, size: 16),
                  const SizedBox(width: 6),
                  Text('${_currentScale.toStringAsFixed(1)}x',
                      style: GoogleFonts.montserrat(
                          color: Colors.white.withOpacity(0.65),
                          fontSize: 8, fontWeight: FontWeight.w600)),
                ]),
              ),
            )),
      ]),
    );
  }
}