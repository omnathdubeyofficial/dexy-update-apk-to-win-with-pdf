import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:video_player/video_player.dart';
import 'package:video_player_win/video_player_win_plugin.dart';
import 'package:window_manager/window_manager.dart';
import 'package:pdfx/pdfx.dart';

const int kServerPort = 8085;
const int kWsPort = 8086;

// Native channel for large‑asset copying (avoids Dart‑heap OOM)
const MethodChannel _assetChannel = MethodChannel('com.dexy.receiver/assets');

// ── Gallery: 55 images – exactly matches Android sender ──────────────────────
const int kGalleryImageCount = 55;
final List<String> kGalleryImages =
    List.generate(kGalleryImageCount, (i) => 'assets/img/${i + 1}.jpg');

const int kPlansImageCount = 15;
final List<String> kPlansImages =
    List.generate(kPlansImageCount, (i) => 'assets/plans/${i + 1}.jpg');

const List<String> kWalkthroughVideos = [
  'assets/video/walkvideo.mp4',
];
const List<String> kDronshootVideos = [
  'assets/video/DJI_20260612135953_0426_D.MP4',
  'assets/video/DJI_20260612140220_0428_D.MP4',
];
const List<String> kDevImages = [
'assets/background/1.jpeg',
'assets/background/2.jpeg',
'assets/background/3.jpeg',
'assets/background/4.jpeg',
'assets/background/5.jpeg',
'assets/background/6.jpeg',
'assets/background/7.jpeg',
'assets/background/8.jpeg',
'assets/background/9.jpeg',
'assets/background/10.jpeg',
'assets/background/11.jpeg',
'assets/background/12.jpeg',
'assets/background/13.jpeg',
'assets/background/14.jpeg',
'assets/background/15.jpeg',
'assets/background/16.jpeg',
'assets/background/17.jpeg',
'assets/background/18.jpeg',
];

// ─────────────────────────── MAIN ───────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    WindowsVideoPlayer.registerWith();
  }
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await windowManager.ensureInitialized();
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1920, 1080),
        center: true,
        backgroundColor: Colors.black,
        titleBarStyle: TitleBarStyle.hidden,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setFullScreen(true);
        await windowManager.setAlwaysOnTop(true);
      },
    );
  } else if (Platform.isAndroid) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  runApp(const ReceiverApp());
}

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Dexy Receiver',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          primaryColor: const Color(0xFFFECD2A),
          scaffoldBackgroundColor: Colors.black,
          textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme),
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
        duration: const Duration(seconds: 2), vsync: this);
    _scale = Tween<double>(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.elasticOut));
    _fade = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl,
            curve: const Interval(0.0, 0.5, curve: Curves.easeIn)));
    _ctrl.forward();
    Timer(const Duration(seconds: 3), () {
      if (mounted)
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const ReceiverScreen()));
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Container(decoration: const BoxDecoration(
            gradient: RadialGradient(
                center: Alignment.center,
                radius: 1.2,
                colors: [Color(0xFF1A1200), Colors.black]),
          )),
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            FadeTransition(
                opacity: _fade,
                child: ScaleTransition(
                    scale: _scale,
                    child: Image.asset('assets/logowithname.png', width: 300,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.video_library, size: 100,
                            color: Color(0xFFFECD2A))))),
            const SizedBox(height: 40),
            FadeTransition(
                opacity: _fade,
                child: SizedBox(width: 36, height: 36,
                    child: CircularProgressIndicator(
                        color: const Color(0xFFFECD2A),
                        strokeWidth: 2.5,
                        backgroundColor: const Color(0xFFFECD2A)
                            .withOpacity(0.1)))),
            const SizedBox(height: 16),
            FadeTransition(
                opacity: _fade,
                child: Text('RECEIVER READY',
                    style: GoogleFonts.outfit(
                        color: const Color(0xFFFECD2A).withOpacity(0.5),
                        fontSize: 11,
                        letterSpacing: 4,
                        fontWeight: FontWeight.w600))),
          ])),
        ]),
      );
}

// ─────────────────────────── RECEIVER SCREEN ───────────────────────────
class ReceiverScreen extends StatefulWidget {
  const ReceiverScreen({super.key});
  @override
  State<ReceiverScreen> createState() => _ReceiverState();
}

class _ReceiverState extends State<ReceiverScreen>
    with TickerProviderStateMixin, WindowListener {
  HttpServer? _httpServer;
  HttpServer? _wsServer;
  final List<WebSocket> _wsSockets = [];
  String _myIP = 'Getting IP...';
  bool _serverRunning = false;

  String _screen = 'home';
  // Bounds-safe gallery index – clamped to actual list length on receive
  int _galleryIdx = 0;
  int _plansIdx = 0;
  int _devIdx = 0;
  int _brochureIdx = 0;

  // Zoom state – separate for gallery, development, and brochure screens
  // Windows has a large 1920×1080+ display so we start at 1.0 (fill screen)
  // and allow pinch-zoom up to 10× for detail inspection
  final TransformationController _galleryZoom = TransformationController();
  final TransformationController _plansZoom = TransformationController();
  final TransformationController _devZoom    = TransformationController();
  final TransformationController _brochureZoom = TransformationController();

  // PdfDoc and cache for Brochure
  PdfDocument? _pdfDoc;
  int _brochureTotalPages = 0;
  final Map<int, Uint8List> _brochurePageCache = {};
  final Map<int, bool> _loadingBrochurePages = {};

  // Windows Media Foundation player — same engine as Vieana Screen.
  VideoPlayerController? _vp;
  bool _videoReady = false;
  bool _videoSurfaceReady = false;
  String? _currentVideoPath;
  bool _videoLoading = false;
  bool _videoEnding = false;
  int _currentVideoIndex = 0;
  String _currentVideoScreen = '';
  String? _videoError;

  // Timer to push video status back to Android sender
  Timer? _statusTimer;

  // Cached file paths for Android asset extraction
  final Map<String, String> _extractedPaths = {};
  bool _videosExtractedDone = false;
  Completer<void>? _videosExtractedCompleter;
  String? _pendingVideoAsset;
  bool _pendingPlayRequest = false;

  // Network monitoring
  Timer? _networkCheckTimer;
  bool _hasNetwork = true;
  bool _isSenderConnected = false;
  String? _lastError;
  bool _showError = false;

  // Animation for home background zoom
  late AnimationController _bgZoomCtrl;
  late Animation<double> _bgZoom;

  @override
  void initState() {
    super.initState();

    // Background zoom animation – only run when visible
    _bgZoomCtrl = AnimationController(
        duration: const Duration(seconds: 12), vsync: this);
    _bgZoomCtrl.repeat(reverse: true);
    _bgZoom = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _bgZoomCtrl, curve: Curves.easeInOut));

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
    }
    _startHttpServer();
    _startWsServer();
    _getIP();
    _preExtractAllVideos();
    _startNetworkMonitor();
  }

  // ── Network monitoring ────────────────────────────────────────────────────
  void _startNetworkMonitor() {
    _networkCheckTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      final hasNet = await _checkNetwork();
      if (hasNet != _hasNetwork && mounted) {
        setState(() => _hasNetwork = hasNet);
      }
    });
  }

  Future<bool> _checkNetwork() async {
    try {
      final ifaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254')) {
            return true;
          }
        }
      }
    } catch (_) {}
    return false;
  }

  void _showErrorPopup(String message) {
    if (!mounted) return;
    _lastError = message;
    _showError = true;
    setState(() {});
    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() {
          _showError = false;
          _lastError = null;
        });
      }
    });
  }

  /// Resolve video paths at startup (desktop plays bundled files directly — no 3GB copy).
  Future<void> _preExtractAllVideos() async {
    for (final v in [...kWalkthroughVideos, ...kDronshootVideos]) {
      try {
        await _resolveVideoPath(v);
        debugPrint('[Receiver] Video path ready: $v');
      } catch (e) {
        debugPrint('[Receiver] Video prep failed for $v: $e');
      }
    }
    _videosExtractedDone = true;
    _videosExtractedCompleter?.complete();
    debugPrint('[Receiver] All video paths ready.');
  }

  Future<void> _ensureVideosExtracted() async {
    if (_videosExtractedDone) return;
    _videosExtractedCompleter ??= Completer<void>();
    await _videosExtractedCompleter!.future;
  }

  Future<void> _getIP() async {
    try {
      String? ip = await NetworkInfo().getWifiIP();
      if (ip == null || ip.isEmpty) {
        final ifaces = await NetworkInterface.list(
            type: InternetAddressType.IPv4);
        for (final iface in ifaces) {
          for (final addr in iface.addresses) {
            if (!addr.isLoopback &&
                !addr.address.startsWith('169.254') &&
                !addr.address.startsWith('127.')) {
              ip = addr.address;
              break;
            }
          }
          if (ip != null) break;
        }
      }
      if (mounted) setState(() => _myIP = ip ?? 'Unknown IP');
    } catch (_) {
      if (mounted) setState(() => _myIP = 'IP Error');
    }
  }

  Future<String> _resolveVideoPath(String assetPath) async {
    // Walkthrough: always prefer dexy_media smooth/playback override if added later.
    if (kWalkthroughVideos.contains(assetPath)) {
      final external = await _externalMediaFile(assetPath);
      if (external != null) {
        _extractedPaths[assetPath] = external.path;
        return external.path;
      }
    }

    if (_extractedPaths.containsKey(assetPath)) {
      return _extractedPaths[assetPath]!;
    }

    // Desktop: play bundled asset directly (no multi-GB copy).
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final bundled = await _bundledAssetOnDisk(assetPath);
      if (bundled != null) {
        debugPrint('[Receiver] Direct bundled play: ${bundled.path}');
        _extractedPaths[assetPath] = bundled.path;
        if (kWalkthroughVideos.contains(assetPath)) {
          unawaited(_ensureFastStartCopy(bundled.path, assetPath));
        }
        return bundled.path;
      }
    }

    final tmp = await getTemporaryDirectory();
    final fname = p.basename(assetPath);
    final dest = File(p.join(tmp.path, fname));

    if (!await dest.exists()) {
      if (Platform.isAndroid) {
        debugPrint('[Receiver] Copying asset via native channel: $assetPath');
        try {
          await _assetChannel.invokeMethod<String>('copyAsset', {
            'assetPath': assetPath,
            'destPath': dest.path,
          });
          debugPrint('[Receiver] Native copy done: ${dest.path}');
        } catch (e) {
          debugPrint(
              '[Receiver] Native copy failed ($e), falling back to chunked Dart copy');
          await _dartChunkedCopy(assetPath, dest);
        }
      } else {
        debugPrint('[Receiver] Extracting asset (native FS copy): $assetPath');
        await _copyAssetToDisk(assetPath, dest);
      }
    } else {
      debugPrint('[Receiver] Asset already extracted: ${dest.path}');
    }

    _extractedPaths[assetPath] = dest.path;
    return dest.path;
  }

  Directory _dexyMediaDir() => Directory(p.join(
        p.dirname(Platform.resolvedExecutable),
        'data',
        'dexy_media',
      ));

  /// Drop optimized files in data/dexy_media/ — smooth file is preferred.
  Future<File?> _externalMediaFile(String assetPath) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return null;
    }
    final dir = _dexyMediaDir();
    if (!await dir.exists()) return null;

    final base = p.basenameWithoutExtension(assetPath);
    final ext = p.extension(assetPath);
    final candidates = [
      '${base}_smooth$ext',
      '${base}_playback$ext',
      p.basename(assetPath),
    ];

    for (final name in candidates) {
      final external = File(p.join(dir.path, name));
      if (await external.exists()) {
        debugPrint('[Receiver] Using dexy_media: ${external.path}');
        return external;
      }
    }
    return null;
  }

  /// One-time ffmpeg remux: moves MP4 index to front for smooth 4K streaming.
  Future<void> _ensureFastStartCopy(String sourcePath, String assetPath) async {
    final mediaDir = _dexyMediaDir();
    if (!await mediaDir.exists()) await mediaDir.create(recursive: true);

    final out = File(p.join(mediaDir.path, p.basename(assetPath)));
    if (await out.exists()) {
      _extractedPaths[assetPath] = out.path;
      return;
    }

    final lock = File(p.join(mediaDir.path, '.${p.basename(assetPath)}.optimizing'));
    if (await lock.exists()) return;

    try {
      await lock.create();
      debugPrint('[Receiver] Optimizing MP4 for streaming playback (one-time)...');
      final result = await Process.run(
        'ffmpeg',
        [
          '-hide_banner',
          '-loglevel',
          'error',
          '-y',
          '-i',
          sourcePath,
          '-c',
          'copy',
          '-movflags',
          '+faststart',
          out.path,
        ],
        runInShell: Platform.isWindows,
      );
      if (result.exitCode == 0 && await out.exists()) {
        _extractedPaths[assetPath] = out.path;
        debugPrint('[Receiver] Faststart copy ready: ${out.path}');
      } else {
        debugPrint('[Receiver] ffmpeg faststart failed: ${result.stderr}');
      }
    } catch (e) {
      debugPrint('[Receiver] ffmpeg not available — using bundled file: $e');
    } finally {
      if (await lock.exists()) await lock.delete();
    }
  }

  /// Copy bundled asset directly from disk — avoids loading multi‑GB files into RAM.
  Future<File?> _bundledAssetOnDisk(String assetPath) async {
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return null;
    }
    final bundled = File(p.join(
      p.dirname(Platform.resolvedExecutable),
      'data',
      'flutter_assets',
      assetPath,
    ));
    if (await bundled.exists()) return bundled;
    return null;
  }

  Future<void> _copyAssetToDisk(String assetPath, File dest) async {
    final bundled = await _bundledAssetOnDisk(assetPath);
    if (bundled != null) {
      debugPrint('[Receiver] OS copy: ${bundled.path} -> ${dest.path}');
      await bundled.copy(dest.path);
      return;
    }
    debugPrint('[Receiver] Fallback chunked Dart copy: $assetPath');
    await _dartChunkedCopy(assetPath, dest);
  }

  Future<void> _dartChunkedCopy(String assetPath, File dest) async {
    final bd = await rootBundle.load(assetPath);
    final rf = await dest.open(mode: FileMode.writeOnly);
    try {
      final buf = bd.buffer;
      final total = bd.lengthInBytes;
      const chunk = 8 * 1024 * 1024; // 8 MB chunks
      int off = 0;
      while (off < total) {
        final len = (off + chunk <= total) ? chunk : (total - off);
        await rf.writeFrom(buf.asUint8List(bd.offsetInBytes + off, len));
        off += len;
      }
    } finally {
      await rf.close();
    }
    debugPrint('[Receiver] Dart chunked copy done: ${dest.path}');
  }

  Future<void> _startHttpServer() async {
    try {
      final handler = const shelf.Pipeline().addHandler(_handleHttp);
      _httpServer = await shelf_io.serve(
          handler, InternetAddress.anyIPv4, kServerPort);
      if (mounted) setState(() => _serverRunning = true);
      debugPrint('HTTP server on :$kServerPort');
    } catch (e) {
      debugPrint('HTTP server error: $e');
      // if (mounted) _showErrorPopup('Server start failed: port $kServerPort in use');
    }
  }

  Future<shelf.Response> _handleHttp(shelf.Request req) async {
    if (req.method == 'POST' && req.url.path == 'connect') {
      return shelf.Response.ok('MATCHED');
    }
    if (req.method == 'GET' && req.url.path == 'status') {
      return shelf.Response.ok(jsonEncode({'server': 'running', 'screen': _screen}),
          headers: {'content-type': 'application/json'});
    }
    return shelf.Response.notFound('Not Found');
  }

  Future<void> _startWsServer() async {
    try {
      _wsServer = await HttpServer.bind(InternetAddress.anyIPv4, kWsPort);
      debugPrint('WS server on :$kWsPort');
      _wsServer!.listen((req) {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          WebSocketTransformer.upgrade(req).then((ws) {
            _wsSockets.add(ws);
            _isSenderConnected = true;
            if (mounted) setState(() {});
            debugPrint('Sender connected via WS');
            ws.add(jsonEncode(
                {'type': 'handshake_ack', 'screen': _screen}));
            ws.listen(
              _handleWsMsg,
              onDone: () {
                _wsSockets.remove(ws);
                if (_wsSockets.isEmpty) {
                  _isSenderConnected = false;
                }
                if (mounted) setState(() {});
                // if (wasConnected && _screen != 'home') {
                //   _showErrorPopup('Remote disconnected - waiting for reconnection');
                // }
                debugPrint('Sender WS disconnected');
              },
              onError: (e) {
                _wsSockets.remove(ws);
                if (_wsSockets.isEmpty) {
                  _isSenderConnected = false;
                }
                if (mounted) setState(() {});
                // if (wasConnected && _screen != 'home') {
                //   _showErrorPopup('Connection error - waiting for reconnection');
                // }
                debugPrint('WS error: $e');
              },
            );
          });
        }
      });
    } catch (e) {
      debugPrint('WS server error: $e');
      // if (mounted) _showErrorPopup('WebSocket server failed to start on port $kWsPort');
    }
  }

  void _handleWsMsg(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';
      switch (type) {
        case 'ping':
          break;
        case 'navigate':
          _onNavigate(data['screen'] as String? ?? 'home');
          break;
        case 'gallery_scroll':
          _onGalleryScroll((data['index'] as num?)?.toInt() ?? 0);
          break;
        case 'plans_scroll':
          _onPlansScroll((data['index'] as num?)?.toInt() ?? 0);
          break;
        case 'dev_scroll':
          _onDevScroll((data['index'] as num?)?.toInt() ?? 0);
          break;
        case 'brochure_scroll':
          _onBrochureScroll((data['index'] as num?)?.toInt() ?? 0);
          break;
        case 'zoom':
          _onZoom(
            (data['scale'] as num?)?.toDouble() ?? 1.0,
            (data['dx'] as num?)?.toDouble() ?? 0.0,
            (data['dy'] as num?)?.toDouble() ?? 0.0,
          );
          break;
        case 'video_select':
          final screen = data['screen'] as String? ?? '';
          final idx = (data['index'] as num?)?.toInt() ?? 0;
          _onVideoSelect(screen, idx);
          break;
        case 'video_control':
          _onVideoControl(
            data['action'] as String? ?? '',
            data['value'],
            data['path'] as String?,
          );
          break;
      }
    } catch (e) {
      debugPrint('WS parse error: $e');
    }
  }

  void _onNavigate(String screen) {
    if (!mounted) return;
    if (_screen == 'walkthrough' || _screen == 'dronshoot') {
      _stopVideo();
    }
    setState(() {
      _screen = screen;
      _videoError = null;
      _galleryZoom.value = Matrix4.identity();
      _plansZoom.value = Matrix4.identity();
      _devZoom.value = Matrix4.identity();
      _brochureZoom.value = Matrix4.identity();
    });
    _syncBackgroundZoom();
    if (screen == 'brochure') {
      _loadBrochurePage(_brochureIdx);
    }
  }

  /// Home zoom keeps scheduling frames. Stop it while a video is on screen
  /// so those frames do not fight playback.
  void _syncBackgroundZoom() {
    if (_screen == 'home') {
      if (!_bgZoomCtrl.isAnimating) {
        _bgZoomCtrl.repeat(reverse: true);
      }
    } else if (_bgZoomCtrl.isAnimating) {
      _bgZoomCtrl.stop();
    }
  }

  void _onGalleryScroll(int idx) {
    if (!mounted) return;
    // Bounds-check: clamp to valid gallery range so no RangeError ever fires
    final safeIdx = idx.clamp(0, kGalleryImages.length - 1);
    setState(() {
      _galleryIdx = safeIdx;
      _galleryZoom.value = Matrix4.identity();
    });
  }

  void _onPlansScroll(int idx) {
    if (!mounted) return;
    final safeIdx = idx.clamp(0, kPlansImages.length - 1);
    setState(() {
      _plansIdx = safeIdx;
      _plansZoom.value = Matrix4.identity();
    });
  }

  void _onDevScroll(int idx) {
    if (!mounted) return;
    final safeIdx = idx.clamp(0, kDevImages.length - 1);
    setState(() {
      _devIdx = safeIdx;
      _devZoom.value = Matrix4.identity();
    });
  }

  /// Zoom handler – syncs Android (43") zoom/pan to Windows (100") receiver.
  /// Scale is transmitted 1:1 (same zoom %).
  /// Pan offsets are multiplied by (100/43 ≈ 2.33) — the physical screen-size
  /// ratio — so a pan gesture that covers X% of the 43" Android screen covers
  /// the same X% of the 100" Windows screen.
  void _onZoom(double scale, double dx, double dy) {
    if (!mounted) return;

    // Android 43" → Windows 100" pan ratio
    const double panMultiplier = 2.33; // 100 / 43
    final double scaledDx = dx * panMultiplier;
    final double scaledDy = dy * panMultiplier;

    final double clampedScale = scale.clamp(0.5, 10.0);

    final m = Matrix4.identity()
      ..translate(scaledDx, scaledDy)
      ..scale(clampedScale);

    setState(() {
      if (_screen == 'gallery') _galleryZoom.value = m;
      else if (_screen == 'plans') _plansZoom.value = m;
      else if (_screen == 'development') _devZoom.value = m;
      else if (_screen == 'brochure') _brochureZoom.value = m;
    });
  }

  void _onVideoSelect(String screen, int idx) {
    if (!mounted) return;
    final vids = screen == 'walkthrough' ? kWalkthroughVideos : kDronshootVideos;
    if (idx >= 0 && idx < vids.length) {
      _currentVideoIndex = idx;
      _currentVideoScreen = screen;
      if (_screen != screen) {
        setState(() {
          _screen = screen;
        });
        _syncBackgroundZoom();
      }
      // Wait 2 frames for Video widget to mount, then play
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted) _playVideo(vids[idx]);
          });
        });
      });
    }
  }

  void _onVideoControl(String action, dynamic value, String? path) {
    debugPrint('VideoControl: $action value=$value path=$path');
    final controller = _vp;
    switch (action) {
      case 'play':
        if (path != null && path != _currentVideoPath) {
          _playVideo(path);
        } else if (_videoLoading || !_videoReady || controller == null) {
          _pendingPlayRequest = true;
        } else if (!controller.value.isPlaying) {
          _videoEnding = false;
          controller.play();
          _startStatusTimer();
        }
        break;
      case 'pause':
        controller?.pause();
        break;
      case 'seek':
        final sec = (value as num?)?.toDouble() ?? 0.0;
        controller?.seekTo(Duration(milliseconds: (sec * 1000).toInt()));
        Future.delayed(const Duration(milliseconds: 80), _pushVideoStatus);
        break;
      case 'volume':
        final vol = ((value as num?)?.toDouble() ?? 1.0).clamp(0.0, 1.0);
        controller?.setVolume(vol);
        break;
    }
  }

  void _startStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      _pushVideoStatus();
    });
  }

  void _stopStatusTimer() {
    _statusTimer?.cancel();
    _statusTimer = null;
  }

  void _pushVideoStatus() {
    if (_wsSockets.isEmpty) return;
    final controller = _vp;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final pos = controller.value.position.inMilliseconds.toDouble();
      final dur = controller.value.duration.inMilliseconds.toDouble();
      final playing = controller.value.isPlaying;
      final msg = jsonEncode({
        'type': 'video_status',
        'screen': _currentVideoScreen,
        'index': _currentVideoIndex,
        'position': pos,
        'duration': dur,
        'playing': playing,
      });
      for (final ws in List<WebSocket>.from(_wsSockets)) {
        try { ws.add(msg); } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Receiver] Status push error: $e');
    }
  }

  void _onVideoTick() {
    final controller = _vp;
    if (controller == null || !mounted || _videoLoading || _videoEnding) return;
    final value = controller.value;
    if (!value.isInitialized || value.duration <= Duration.zero) return;
    if (!value.isCompleted || value.isPlaying) return;

    _videoEnding = true;
    _stopStatusTimer();
    final old = controller;
    _vp = null;
    _currentVideoPath = null;
    old.removeListener(_onVideoTick);
    setState(() {
      _screen = 'home';
      _videoReady = false;
      _videoSurfaceReady = false;
      _videoLoading = false;
    });
    _syncBackgroundZoom();
    Future<void>(() async {
      try { await old.dispose(); } catch (_) {}
    });
  }

  Future<VideoPlayerController> _openVideoFile(String filePath) async {
    final controller = VideoPlayerController.file(File(filePath));
    try {
      await controller.initialize().timeout(const Duration(seconds: 45));
      await controller.setVolume(1.0);
      return controller;
    } catch (e) {
      try { await controller.dispose(); } catch (_) {}
      rethrow;
    }
  }

  void _showOpened(VideoPlayerController next, String assetPath) {
    final old = _vp;
    if (old != null && !identical(old, next)) {
      old.removeListener(_onVideoTick);
    }
    _vp = next;
    next.addListener(_onVideoTick);
    _currentVideoPath = assetPath;
    _videoReady = true;
    _videoSurfaceReady = true;
    _videoLoading = false;
    _videoError = null;
    _videoEnding = false;
    if (mounted) setState(() {});
    if (old != null && !identical(old, next)) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        try { await old.dispose(); } catch (_) {}
      });
    }
  }

  Future<void> _playVideo(String assetPath) async {
    if (_videoLoading) {
      _pendingVideoAsset = assetPath;
      return;
    }

    final existing = _vp;
    if (_currentVideoPath == assetPath &&
        existing != null &&
        existing.value.isInitialized &&
        _videoReady &&
        _videoSurfaceReady) {
      _stopStatusTimer();
      _videoEnding = false;
      try {
        await existing.seekTo(Duration.zero);
        await existing.setVolume(1.0);
        await existing.play();
      } catch (_) {}
      _startStatusTimer();
      return;
    }

    _videoLoading = true;
    _videoError = null;
    _videoEnding = false;
    _stopStatusTimer();
    // Keep the current frame up. A black cover is only for the first open.
    if (existing == null || !existing.value.isInitialized) {
      _videoReady = false;
      _videoSurfaceReady = false;
      if (mounted) setState(() {});
    }

    try {
      await _ensureVideosExtracted();
      final resolved = await _resolveVideoPath(assetPath);
      if (!await File(resolved).exists()) {
        throw StateError('Video file missing: $resolved');
      }
      debugPrint('[Receiver] Playing resolved path: $resolved');
      final next = await _openVideoFile(resolved);
      _showOpened(next, assetPath);
      await next.play();
      _startStatusTimer();
      if (_pendingPlayRequest) {
        _pendingPlayRequest = false;
        await next.play();
      }
    } catch (e) {
      debugPrint('[Receiver] Play error: $e – retrying');
      try {
        final resolved = _extractedPaths[assetPath] ?? assetPath;
        if (!await File(resolved).exists()) {
          throw StateError('Video file missing: $resolved');
        }
        final next = await _openVideoFile(resolved);
        _showOpened(next, assetPath);
        await next.play();
        _startStatusTimer();
      } catch (e2) {
        debugPrint('[Receiver] Retry also failed: $e2');
        _videoLoading = false;
        if (_vp == null || !_vp!.value.isInitialized) {
          _videoReady = false;
          _videoSurfaceReady = false;
        }
        _videoError = 'Video playback failed. Tap to retry.';
        if (mounted) {
          setState(() {});
          final msg = e2.toString();
          _showErrorPopup(
            'Video Error: ${msg.isNotEmpty ? msg.substring(0, msg.length.clamp(0, 120)) : "Playback failed"}',
          );
        }
      }
    }

    if (_videoLoading) {
      _videoLoading = false;
      if (mounted) setState(() {});
    }

    final pending = _pendingVideoAsset;
    _pendingVideoAsset = null;
    if (pending != null && pending != assetPath && mounted) {
      _playVideo(pending);
    }
  }

  Future<void> _stopVideo() async {
    _stopStatusTimer();
    _currentVideoPath = null;
    _videoReady = false;
    _videoSurfaceReady = false;
    _videoLoading = false;
    _videoEnding = false;
    _pendingVideoAsset = null;
    _pendingPlayRequest = false;
    final old = _vp;
    _vp = null;
    if (old != null) {
      old.removeListener(_onVideoTick);
      try { await old.pause(); } catch (_) {}
      try { await old.dispose(); } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _networkCheckTimer?.cancel();
    _stopStatusTimer();
    try { _httpServer?.close(); } catch (_) {}
    try { _wsServer?.close(); } catch (_) {}
    for (final ws in _wsSockets) {
      try { ws.close(); } catch (_) {}
    }
    final oldVideo = _vp;
    _vp = null;
    if (oldVideo != null) {
      oldVideo.removeListener(_onVideoTick);
      try { oldVideo.dispose(); } catch (_) {}
    }
    try { _bgZoomCtrl.dispose(); } catch (_) {}
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    try { _galleryZoom.dispose(); } catch (_) {}
    try { _plansZoom.dispose(); } catch (_) {}
    try { _devZoom.dispose(); } catch (_) {}
    try { _brochureZoom.dispose(); } catch (_) {}
    try { _pdfDoc?.close(); } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    switch (_screen) {
      case 'gallery':
        body = _buildImageBody(
          kGalleryImages,
          _galleryIdx,
          _galleryZoom,
        );
        break;

      case 'plans':
        body = _buildImageBody(
          kPlansImages,
          _plansIdx,
          _plansZoom,
          fit: BoxFit.contain,
        );
        break;

      case 'walkthrough':
      case 'dronshoot':
        body = _buildVideoBody();
        break;

      case 'development':
        body = _buildImageBody(
          kDevImages,
          _devIdx,
          _devZoom,
        );
        break;

      case 'brochure':
        body = _buildBrochureBody();
        break;

      case 'home':
      default:
        body = _buildHomeBody();
        break;
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: body),
          // IP badge – small, bottom‑right
          Positioned(
            bottom: 8,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _myIP,
                style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 8,
                    fontFamily: 'monospace'),
              ),
            ),
          ),
          // // Sender connection status indicator
          // if (_isSenderConnected)
          //   Positioned(
          //     top: 12,
          //     right: 12,
          //     child: Container(
          //       padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          //       decoration: BoxDecoration(
          //         color: const Color(0xFF4ADE80).withOpacity(0.15),
          //         borderRadius: BorderRadius.circular(20),
          //         border: Border.all(
          //             color: const Color(0xFF4ADE80).withOpacity(0.4), width: 1),
          //       ),
          //       child: Row(
          //         mainAxisSize: MainAxisSize.min,
          //         children: [
          //           Container(
          //             width: 6, height: 6,
          //             decoration: const BoxDecoration(
          //               shape: BoxShape.circle,
          //               color: Color(0xFF4ADE80),
          //             ),
          //           ),
          //           const SizedBox(width: 6),
          //           const Text(
          //             'REMOTE CONNECTED',
          //             style: TextStyle(
          //               color: Color(0xFF4ADE80),
          //               fontSize: 8,
          //               fontWeight: FontWeight.w700,
          //               letterSpacing: 1.5,
          //               fontFamily: 'monospace',
          //             ),
          //           ),
          //         ],
          //       ),
          //     ),
          //   ),
          // // No network overlay
          // if (!_hasNetwork)
          //   Positioned.fill(
          //     child: Container(
          //       color: Colors.black.withOpacity(0.85),
          //       child: Center(
          //         child: Container(
          //           margin: const EdgeInsets.all(40),
          //           padding: const EdgeInsets.all(40),
          //           decoration: BoxDecoration(
          //             color: const Color(0xFF1A1200),
          //             borderRadius: BorderRadius.circular(24),
          //             border: Border.all(
          //                 color: const Color(0xFFFECD2A).withOpacity(0.3),
          //                 width: 2),
          //             boxShadow: [
          //               BoxShadow(
          //                 color: const Color(0xFFFECD2A).withOpacity(0.1),
          //                 blurRadius: 40,
          //                 spreadRadius: 10,
          //               ),
          //             ],
          //           ),
          //           child: Column(
          //             mainAxisSize: MainAxisSize.min,
          //             children: [
          //               const Icon(Icons.wifi_off_rounded,
          //                   size: 64, color: Color(0xFFFECD2A)),
          //               const SizedBox(height: 24),
          //               Text(
          //                 'NO NETWORK DETECTED',
          //                 style: GoogleFonts.outfit(
          //                   color: const Color(0xFFFECD2A),
          //                   fontSize: 22,
          //                   fontWeight: FontWeight.w700,
          //                   letterSpacing: 3,
          //                 ),
          //               ),
          //               const SizedBox(height: 12),
          //               Text(
          //                 'Please connect to a LAN or WiFi network',
          //                 style: GoogleFonts.outfit(
          //                   color: Colors.white.withOpacity(0.5),
          //                   fontSize: 14,
          //                 ),
          //               ),
          //               const SizedBox(height: 8),
          //               Text(
          //                 'The receiver requires a network connection\nto communicate with the remote.',
          //                 style: GoogleFonts.outfit(
          //                   color: Colors.white.withOpacity(0.3),
          //                   fontSize: 12,
          //                 ),
          //                 textAlign: TextAlign.center,
          //               ),
          //             ],
          //           ),
          //         ),
          //       ),
          //     ),
          //   ),
          // // Sender disconnected overlay (only show if we have network but sender is gone)
          // if (_hasNetwork && !_isSenderConnected && _screen != 'home')
          //   Positioned.fill(
          //     child: Container(
          //       color: Colors.black.withOpacity(0.8),
          //       child: Center(
          //         child: Container(
          //           margin: const EdgeInsets.all(40),
          //           padding: const EdgeInsets.all(40),
          //           decoration: BoxDecoration(
          //             color: const Color(0xFF1A0A00),
          //             borderRadius: BorderRadius.circular(24),
          //             border: Border.all(
          //                 color: Colors.orangeAccent.withOpacity(0.3),
          //                 width: 2),
          //           ),
          //           child: Column(
          //             mainAxisSize: MainAxisSize.min,
          //             children: [
          //               const Icon(Icons.phone_android_rounded,
          //                   size: 64, color: Colors.orangeAccent),
          //               const SizedBox(height: 24),
          //               Text(
          //                 'REMOTE DISCONNECTED',
          //                 style: GoogleFonts.outfit(
          //                   color: Colors.orangeAccent,
          //                   fontSize: 22,
          //                   fontWeight: FontWeight.w700,
          //                   letterSpacing: 3,
          //                 ),
          //               ),
          //               const SizedBox(height: 12),
          //               Text(
          //                 'The Android remote has lost connection.',
          //                 style: GoogleFonts.outfit(
          //                   color: Colors.white.withOpacity(0.5),
          //                   fontSize: 14,
          //                 ),
          //               ),
          //               const SizedBox(height: 8),
          //               Text(
          //                 'Waiting for reconnection...',
          //                 style: GoogleFonts.outfit(
          //                   color: Colors.white.withOpacity(0.3),
          //                   fontSize: 12,
          //                 ),
          //               ),
          //             ],
          //           ),
          //         ),
          //       ),
          //     ),
          //   ),
          // Error popup overlay (video errors etc.; connection popups are disabled above)
          if (_showError && _lastError != null)
            Positioned(
              top: 40,
              left: 0,
              right: 0,
              child: Center(
                child: AnimatedOpacity(
                  opacity: _showError ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2A0A0A),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.redAccent.withOpacity(0.5), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.redAccent.withOpacity(0.2),
                          blurRadius: 20,
                          spreadRadius: 5,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 20, color: Colors.redAccent),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _lastError!,
                            style: GoogleFonts.outfit(
                              color: Colors.white.withOpacity(0.9),
                              fontSize: 12,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildImageBody(
    List<String> images,
    int index,
    TransformationController zoom, {
    BoxFit fit = BoxFit.cover,
  }) {
    final safeIdx = index.clamp(0, images.length - 1);
    return Container(
      color: Colors.black,
      child: InteractiveViewer(
        transformationController: zoom,
        minScale: 0.8,
        maxScale: 10.0,
        clipBehavior: Clip.hardEdge,
        child: SizedBox.expand(
          child: Image.asset(
            images[safeIdx],
            fit: fit,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, size: 80, color: Colors.white24),
            ),
          ),
        ),
      ),
    );
  }

  // ── Video body ───────────────────────────────────────────────────────────────
  Widget _buildVideoBody() {
    final controller = _vp;
    final showVideo = controller != null &&
        controller.value.isInitialized &&
        _videoReady;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showVideo)
            _CoverVideo(
              key: ObjectKey(controller),
              controller: controller,
            ),
          if (_videoError != null)
            GestureDetector(
              onTap: () {
                final vids = _currentVideoScreen == 'walkthrough'
                    ? kWalkthroughVideos
                    : kDronshootVideos;
                if (_currentVideoIndex < vids.length) {
                  _playVideo(vids[_currentVideoIndex]);
                }
              },
              child: ColoredBox(
                color: Colors.black87,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.error_outline,
                          size: 48, color: Color(0xFFFECD2A)),
                      const SizedBox(height: 12),
                      Text(_videoError!,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 14),
                          textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 8),
                        decoration: BoxDecoration(
                          border: Border.all(
                              color: const Color(0xFFFECD2A), width: 1),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('RETRY',
                            style: TextStyle(
                                color: Color(0xFFFECD2A), fontSize: 12)),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (!showVideo)
            const Center(
              child: CircularProgressIndicator(
                  color: Color(0xFFFECD2A), strokeWidth: 2.5),
            ),
        ],
      ),
    );
  }

  // ── Home body ────────────────────────────────────────────────────────────────
  Widget _buildHomeBody() {
    return Container(
      key: const ValueKey('homeBody'),
      color: Colors.black,
      child: Stack(
        children: [
          // Animated background with zoom
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _bgZoomCtrl,
              builder: (_, __) => Transform.scale(
                scale: _bgZoom.value,
                child: Image.asset(
                  'assets/default_background.jpg',
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, __, ___) => Container(color: Colors.black),
                ),
              ),
            ),
          ),
          // Dark overlay – reduced to 10% for more visible background
          Positioned.fill(
            child: Container(color: Colors.black.withOpacity(0.1)),
          ),
          Center(
            child: Image.asset(
              'assets/logowithname.png',
              width: 420,
              filterQuality: FilterQuality.high,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.video_library,
                size: 100,
                color: Color(0xFFFECD2A),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _onBrochureScroll(int idx) {
    if (!mounted) return;
    if (_pdfDoc != null) {
      final safeIdx = idx.clamp(0, _brochureTotalPages - 1);
      setState(() {
        _brochureIdx = safeIdx;
        _brochureZoom.value = Matrix4.identity();
      });
      _loadBrochurePage(safeIdx);
      _loadBrochurePage(safeIdx + 1);
      _loadBrochurePage(safeIdx - 1);
    } else {
      setState(() {
        _brochureIdx = idx;
        _brochureZoom.value = Matrix4.identity();
      });
      _loadBrochurePage(idx);
    }
  }

  Future<void> _loadBrochurePage(int pageIdx) async {
    if (_pdfDoc == null) {
      try {
        _pdfDoc = await PdfDocument.openAsset('assets/brochure/brochure.pdf');
        _brochureTotalPages = _pdfDoc!.pagesCount;
      } catch (e) {
        debugPrint('[Receiver] Error opening PDF: $e');
        return;
      }
    }
    
    if (_brochurePageCache.containsKey(pageIdx) || _loadingBrochurePages[pageIdx] == true) return;
    if (pageIdx < 0 || pageIdx >= _brochureTotalPages) return;
    
    _loadingBrochurePages[pageIdx] = true;
    try {
      final page = await _pdfDoc!.getPage(pageIdx + 1); // 1-indexed in pdfx
      final img = await page.render(
        width: page.width * 3,
        height: page.height * 3,
        format: PdfPageImageFormat.jpeg,
      );
      await page.close();
      if (img != null && mounted) {
        setState(() {
          _brochurePageCache[pageIdx] = img.bytes;
        });
      }
    } catch (e) {
      debugPrint('[Receiver] Error rendering brochure page $pageIdx: $e');
    } finally {
      _loadingBrochurePages[pageIdx] = false;
    }
  }

  Widget _buildBrochureBody() {
    final bytes = _brochurePageCache[_brochureIdx];
    if (bytes == null) {
      _loadBrochurePage(_brochureIdx);
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
            color: Color(0xFFFECD2A),
            strokeWidth: 2.5,
          ),
        ),
      );
    }
    return Container(
      color: Colors.black,
      child: InteractiveViewer(
        transformationController: _brochureZoom,
        minScale: 0.8,
        maxScale: 10.0,
        clipBehavior: Clip.hardEdge,
        child: SizedBox.expand(
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, __, ___) => const Center(
              child: Icon(Icons.broken_image, size: 80, color: Colors.white24),
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-bleed video, same layout as Vieana Screen. The surface is not covered
/// by a black layer once the first frame is ready, so playback does not blink.
class _CoverVideo extends StatelessWidget {
  const _CoverVideo({super.key, required this.controller});

  final VideoPlayerController controller;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    final width = size.width > 1 ? size.width : 1920.0;
    final height = size.height > 1 ? size.height : 1080.0;
    return RepaintBoundary(
      child: FittedBox(
        fit: BoxFit.cover,
        clipBehavior: Clip.hardEdge,
        child: SizedBox(
          width: width,
          height: height,
          child: VideoPlayer(controller),
        ),
      ),
    );
  }
}