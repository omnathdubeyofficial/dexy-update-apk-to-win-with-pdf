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
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
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

];

// ─────────────────────────── MAIN ───────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
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

  // MediaKit player
  late Player _player;
  VideoController? _videoCtrl;
  bool _videoReady = false;
  bool _videoSurfaceReady = false;
  String? _currentVideoPath;
  bool _videoLoading = false;
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

  // Animation for home background zoom
  late AnimationController _bgZoomCtrl;
  late Animation<double> _bgZoom;

  @override
  void initState() {
    super.initState();
    _player = Player(configuration: const PlayerConfiguration(
      bufferSize: 512 * 1024 * 1024,
      logLevel: MPVLogLevel.warn,
    ));
    _videoCtrl = VideoController(
      _player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
        hwdec: 'auto-safe',
      ),
    );

    // Background zoom animation – only run when visible
    _bgZoomCtrl = AnimationController(
        duration: const Duration(seconds: 12), vsync: this);
    _bgZoomCtrl.repeat(reverse: true);
    _bgZoom = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _bgZoomCtrl, curve: Curves.easeInOut));

    // Listen for video completion → go back to home
    _player.streams.completed.listen((_) {
      if (mounted) {
        _stopStatusTimer();
        setState(() {
          _screen = 'home';
          _videoReady = false;
          _videoSurfaceReady = false;
          _videoLoading = false;
          _currentVideoPath = null;
        });
        try { _player.stop(); } catch (_) {}
      }
    });

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      windowManager.addListener(this);
    }
    _startHttpServer();
    _startWsServer();
    _getIP();
    _preExtractAllVideos();
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

  String _toFileUri(String path) {
    if (path.startsWith('file://')) return path;
    return Uri.file(path).toString();
  }

  /// Wait until mpv has decoded video and buffered enough for smooth 4K playback.
  Future<void> _waitForPlaybackReady({
    Duration timeout = const Duration(seconds: 45),
    Duration minBuffer = const Duration(seconds: 3),
  }) async {
    final deadline = DateTime.now().add(timeout);
    DateTime? decodedAt;

    while (DateTime.now().isBefore(deadline)) {
      final s = _player.state;
      final hasVideo =
          (s.width ?? 0) > 0 && s.duration > Duration.zero;
      if (hasVideo && decodedAt == null) decodedAt = DateTime.now();

      final buffered = !s.buffering && s.buffer >= minBuffer;
      if (hasVideo && buffered) return;

      // Decoded but buffer slow — don't block more than 12s after first frame.
      if (hasVideo &&
          decodedAt != null &&
          DateTime.now().difference(decodedAt!) > const Duration(seconds: 12)) {
        debugPrint('[Receiver] Starting with partial buffer (${s.buffer.inSeconds}s)');
        return;
      }

      await Future.delayed(const Duration(milliseconds: 80));
    }

    final s = _player.state;
    if ((s.width ?? 0) > 0 && s.duration > Duration.zero) {
      debugPrint('[Receiver] Buffer wait timeout — starting playback anyway');
      return;
    }
    throw StateError('Video decode timeout');
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
            debugPrint('Sender connected via WS');
            ws.add(jsonEncode(
                {'type': 'handshake_ack', 'screen': _screen}));
            ws.listen(
              _handleWsMsg,
              onDone: () {
                _wsSockets.remove(ws);
                debugPrint('Sender WS disconnected');
              },
              onError: (e) {
                _wsSockets.remove(ws);
                debugPrint('WS error: $e');
              },
            );
          });
        }
      });
    } catch (e) {
      debugPrint('WS server error: $e');
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
    if (screen == 'brochure') {
      _loadBrochurePage(_brochureIdx);
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
    switch (action) {
      case 'play':
        if (path != null && path != _currentVideoPath) {
          _playVideo(path);
        } else if (_videoLoading || !_videoReady) {
          _pendingPlayRequest = true;
        } else if (!_player.state.playing) {
          _player.play();
          _startStatusTimer();
        }
        break;
      case 'pause':
        _player.pause();
        break;
      case 'seek':
        final sec = (value as num?)?.toDouble() ?? 0.0;
        _player.seek(Duration(milliseconds: (sec * 1000).toInt()));
        Future.delayed(const Duration(milliseconds: 80), _pushVideoStatus);
        break;
      case 'volume':
        final vol = (value as num?)?.toDouble() ?? 1.0;
        _player.setVolume((vol * 100.0).clamp(0.0, 100.0));
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
    try {
      final pos = _player.state.position.inMilliseconds.toDouble();
      final dur = _player.state.duration.inMilliseconds.toDouble();
      final playing = _player.state.playing;
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

  Future<void> _playVideo(String assetPath) async {
    if (_videoLoading) {
      _pendingVideoAsset = assetPath;
      return;
    }

    // Only skip reopen when decode surface is live on the big display.
    if (_currentVideoPath == assetPath &&
        _videoReady &&
        _videoSurfaceReady) {
      _stopStatusTimer();
      try {
        await _player.seek(Duration.zero);
        await _player.setVolume(100.0);
        await _player.play();
      } catch (_) {}
      _startStatusTimer();
      return;
    }

    _videoLoading = true;
    _videoSurfaceReady = false;
    _videoError = null;
    _stopStatusTimer();
    if (mounted) setState(() {});

    try {
      await _ensureVideosExtracted();
      final resolved = await _resolveVideoPath(assetPath);
      if (!await File(resolved).exists()) {
        throw StateError('Video file missing: $resolved');
      }
      debugPrint('[Receiver] Playing resolved path: $resolved');

      await _player.stop();
      await Future.delayed(const Duration(milliseconds: 100));

      final uri = _toFileUri(resolved);
      await _player.open(Media(uri), play: false);
      await _waitForPlaybackReady(
        minBuffer: const Duration(seconds: 3),
      );
      await _player.setVolume(100.0);
      await _player.play();

      _currentVideoPath = assetPath;
      _videoReady = true;
      _videoSurfaceReady = true;
      _startStatusTimer();
      if (_pendingPlayRequest) {
        _pendingPlayRequest = false;
        await _player.play();
      }
    } catch (e) {
      debugPrint('[Receiver] Play error: $e – retrying with fresh player');
      _videoReady = false;
      _videoSurfaceReady = false;
      _videoCtrl = null;

      try {
        await _player.dispose();
      } catch (_) {}
      try {
        _player = Player(configuration: const PlayerConfiguration(
          bufferSize: 512 * 1024 * 1024,
          logLevel: MPVLogLevel.warn,
        ));
        _videoCtrl = VideoController(
          _player,
          configuration: const VideoControllerConfiguration(
            enableHardwareAcceleration: true,
            hwdec: 'auto',
          ),
        );
      } catch (_) {}

      try {
        final resolved = _extractedPaths[assetPath] ?? assetPath;
        final uri = _toFileUri(resolved);
        await _player.open(Media(uri), play: false);
        await _waitForPlaybackReady(
          minBuffer: const Duration(seconds: 3),
        );
        await _player.setVolume(100.0);
        await _player.play();

        _currentVideoPath = assetPath;
        _videoReady = true;
        _videoSurfaceReady = true;
        _startStatusTimer();
      } catch (e2) {
        debugPrint('[Receiver] Retry also failed: $e2');
        _videoError = 'Video playback failed. Tap to retry.';
      }
    }

    _videoLoading = false;
    if (mounted) setState(() {});

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
    _pendingVideoAsset = null;
    _pendingPlayRequest = false;
    try {
      await _player.stop();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _stopStatusTimer();
    try { _httpServer?.close(); } catch (_) {}
    try { _wsServer?.close(); } catch (_) {}
    for (final ws in _wsSockets) {
      try { ws.close(); } catch (_) {}
    }
    try { _player.dispose(); } catch (_) {}
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
        ],
      ),
    );
  }

  Widget _buildImageBody(
    List<String> images,
    int index,
    TransformationController zoom,
  ) {
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
            fit: BoxFit.cover,
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
    if (_videoCtrl == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
              color: Color(0xFFFECD2A), strokeWidth: 2.5),
        ),
      );
    }
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: _videoCtrl!,
            fit: BoxFit.cover,
            controls: NoVideoControls,
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
          else if (_videoLoading && !_videoReady)
            ColoredBox(
              color: Colors.black,
              child: const Center(
                child: CircularProgressIndicator(
                    color: Color(0xFFFECD2A), strokeWidth: 2.5),
              ),
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