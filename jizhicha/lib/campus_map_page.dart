import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'campus_map_controller.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

/// 校园地图地址（学校官方 GIS 站点，高德 H5，公网可达，不需要校园加速器）。
const String campusMapUrl = 'https://gis.huse.edu.cn/cmipsh5/#/';

/// 允许在应用内打开的域名后缀（学校域名）。
const String campusMapHostSuffix = 'huse.edu.cn';

/// 与 Android 原生层（`android/app/src/main/kotlin/com/one/huaji/CampusMapGeolocation.kt`）
/// 通信的 Channel 名。必须是两端字面量一致。
const String campusMapChannelName = 'com.one.huaji/campus_map';

/// 主机是否属于学校域名（`huse.edu.cn` 或其子域）。
///
/// 单独抽成纯函数是为了可单测：它是「应用内导航白名单」和「原生层定位放行白名单」
/// 共用的判据，写错的后果是**把任意站点放进应用内的 WebView**。
bool isCampusMapHost(String host) {
  final String normalized = host.toLowerCase();
  if (normalized.isEmpty) return false;
  return normalized == campusMapHostSuffix ||
      normalized.endsWith('.$campusMapHostSuffix');
}

/// 这个 URL 是否应该留在应用内的 WebView 里。
///
/// 只放行 `http/https` + 学校域名；其余（外站、`intent://`、`tel:`、非法串）
/// 一律交给系统浏览器/系统处理，避免第三方页面在我们的 WebView 里自由导航。
bool isInAppNavigableUrl(String url) {
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return false;
  if (uri.scheme != 'https' && uri.scheme != 'http') return false;
  return isCampusMapHost(uri.host);
}

/// 应用内校园地图页：用官方 `webview_flutter`（系统 WebView）加载学校 GIS 高德 H5。
///
/// 用它的两个地方：
/// 1. 「更多」里的校园地图入口；
/// 2. 课表里无法识别楼栋时的跳转落点。
///
/// 定位链路：
/// 1. Dart 调 `requestLocationPermission`（MethodChannel）→ Kotlin 弹系统运行时权限；
/// 2. Dart 用插件官方的 `setGeolocationPermissionsPromptCallbacks` 决定
///    「这个 origin 允不允许用定位」，只放行学校域名。
///
/// ⚠️ 历史教训（2026-11-02 真机闪退，别走回头路）：旧实现让原生层把 WebView 的
/// `WebChromeClient` 换成自己的包装器去实现 `onGeolocationPermissionsShowPrompt`。
/// 但 `webview_flutter_android` 的 `WebViewProxyApi.setWebChromeClient` 断言
/// `client is SecureWebChromeClient`，换掉即在**平台线程**抛 `AssertionError`，
/// 直接 FATAL 杀进程 —— 表现就是「点校园地图立刻闪退」。
/// 正解是插件自己暴露的回调 API，原生层不再碰 ChromeClient。
///
/// 安全红线：**不实现 `onReceivedSslError` 放行**——证书错误一律按系统默认取消加载
/// （`webview_flutter` 也没有暴露放行入口）。
class CampusMapPage extends StatefulWidget {
  const CampusMapPage({super.key});

  @override
  State<CampusMapPage> createState() => _CampusMapPageState();
}

class _CampusMapPageState extends State<CampusMapPage> {
  static const MethodChannel _channel = MethodChannel(campusMapChannelName);

  /// 当前平台是否有 WebView 实现。桌面端（Windows）没有，此时退化成外链卡片。
  WebViewController? _controller;

  bool _embedding = false;
  bool _loading = true;
  /// 首屏迟迟不完成时给用户的提示（不是错误，只是"慢"）。
  bool _slowHint = false;
  Timer? _slowTimer;
  bool _locationDenied = false;
  int _progress = 0;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    // 没有注册 WebView 平台实现时（Windows 桌面 / 单测环境）不要构造
    // WebViewController —— 它会直接抛 UnsupportedError。
    _embedding = WebViewPlatform.instance != null;
    if (!_embedding) {
      _loading = false;
      return;
    }
    // 复用进程内的同一个 WebView（见 campus_map_controller.dart）：
    // 第二次打开不再重新加载，直接显示上次那张图 —— 这是"打开一次后本地保存"的主要手段。
    _controller = CampusMapController.instance.obtain(campusMapUrl)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: _onProgress,
          onPageStarted: _onPageStarted,
          onPageFinished: _onPageFinished,
          onWebResourceError: _onWebResourceError,
          onNavigationRequest: _onNavigationRequest,
        ),
      );
    // WebView 的平台视图要等第一帧挂到视图树之后，原生层才找得到这个 WebView。
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    // 只 detach，不销毁：控制器留给下次打开复用（空闲超时才真正释放）。
    CampusMapController.instance.release();
    _controller = null;
    super.dispose();
  }

  /// 打开页面的初始化顺序：底色 → 定位包装器 → 定位权限 → 加载页面。
  ///
  /// 底色先设是为了深色主题下不出现白闪（WebView 自己的默认底色是白的）。
  Future<void> _bootstrap() async {
    if (!mounted) return;
    final Color surface = Theme.of(context).colorScheme.surface;
    try {
      await _controller?.setBackgroundColor(surface);
    } on Exception {
      // 某些平台实现不支持，忽略即可（外层容器已经铺了底色）。
    }
    await _configureGeolocation();
    await _requestLocationPermission();
    await _loadMap();
  }

  /// 用插件官方 API 决定「哪个来源可以用定位」。
  ///
  /// `webview_flutter_android` 自己持有 `SecureWebChromeClient`，并把它接到的
  /// `onGeolocationPermissionsShowPrompt` 转发给我们这里注册的回调 —— 这才是
  /// 官方支持的做法（见文件头的历史教训）。
  ///
  /// 只放行学校域名（`isCampusMapHost`）；其余来源一律拒绝，避免校外的第三方
  /// 页面在我们的 WebView 里拿到位置。
  Future<void> _configureGeolocation() async {
    final controller = _controller;
    if (controller == null) return;
    final platform = controller.platform;
    // 非 Android（Windows 预览、iOS）没有这个 API，保持平台默认行为即可。
    if (platform is! AndroidWebViewController) return;
    await platform.setGeolocationPermissionsPromptCallbacks(
      onShowPrompt: (GeolocationPermissionsRequestParams request) async {
        final String? host = Uri.tryParse(request.origin)?.host;
        final bool allow = host != null && isCampusMapHost(host);
        return GeolocationPermissionsResponse(allow: allow, retain: true);
      },
    );
  }

  /// 申请系统运行时定位权限。拒绝不阻断地图（只是不能定位到当前位置）。
  Future<void> _requestLocationPermission() async {
    bool granted = false;
    try {
      granted =
          await _channel.invokeMethod<bool>('requestLocationPermission') ?? false;
    } on Exception {
      granted = false;
    }
    if (!mounted) return;
    setState(() => _locationDenied = !granted);
  }

  /// 加载地图。[force] 为 true 时强制重新拉取（下拉/刷新按钮）。
  Future<void> _loadMap({bool force = false}) async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    // 已经加载过且不是强制刷新 ⇒ 直接复用内存里的页面，秒开。
    if (!force && CampusMapController.instance.isLoaded) {
      setState(() {
        _loading = false;
        _progress = 100;
        _loadError = null;
        _slowHint = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _progress = 0;
      _loadError = null;
      _slowHint = false;
    });
    // 首屏要拉高德 JS SDK（约 350KB）与瓦片，出网慢时十几秒都可能。
    // 超过 15 秒还没完成就浮出一条"慢"提示，让用户知道不是卡死。
    _slowTimer?.cancel();
    _slowTimer = Timer(const Duration(seconds: 15), () {
      if (!mounted || !_loading) return;
      setState(() => _slowHint = true);
    });
    await controller.loadRequest(Uri.parse(campusMapUrl));
  }

  Future<void> _refresh() async {
    final WebViewController? controller = _controller;
    if (controller == null) return;
    setState(() {
      _loading = true;
      _progress = 0;
      _loadError = null;
    });
    await controller.reload();
  }

  /// 兜底：用系统浏览器打开（外置浏览器有自己的定位授权，不受本项目权限影响）。
  Future<void> _openInBrowser([String? url]) async {
    final String target = url ?? campusMapUrl;
    bool opened = false;
    try {
      opened = await launchUrl(
        Uri.parse(target),
        mode: LaunchMode.externalApplication,
      );
    } on Exception {
      opened = false;
    }
    if (!opened && mounted) {
      final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        const SnackBar(
          content: Text('打不开浏览器，请检查系统里是否有可用的浏览器'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _onProgress(int progress) {
    if (!mounted) return;
    setState(() {
      _progress = progress;
      if (progress >= 100) {
        _loading = false;
        _slowHint = false;
        _slowTimer?.cancel();
      }
    });
  }

  void _onPageStarted(String url) {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
  }

  void _onPageFinished(String url) {
    _slowTimer?.cancel();
    // 登记"已经加载过"，下次进页面直接复用。
    if (isCampusMapHost(Uri.tryParse(url)?.host ?? '')) {
      CampusMapController.instance.markLoaded(url);
    }
    if (!mounted) return;
    // 只收掉加载指示；错误态由 _onWebResourceError 决定，不能在这里清掉。
    setState(() => _loading = false);
  }

  /// 主文档加载失败才展示错误页；子资源（图片/瓦片）失败不打扰用户。
  void _onWebResourceError(WebResourceError error) {
    if (!mounted) return;
    if (error.isForMainFrame == false) return;
    setState(() {
      _loading = false;
      _loadError = '无法加载学校地图站点（${error.description}，错误码 ${error.errorCode}）。'
          '请检查网络后重试，或用系统浏览器打开。';
    });
  }

  /// 站外链接不在应用内打开：既避免被第三方页面接管，也保证站外行为与系统一致。
  NavigationDecision _onNavigationRequest(NavigationRequest request) {
    if (!request.isMainFrame) return NavigationDecision.navigate;
    if (isInAppNavigableUrl(request.url)) return NavigationDecision.navigate;
    _openInBrowser(request.url);
    return NavigationDecision.prevent;
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      // 深色主题下不要白闪：页面底色跟主题走，WebView 未绘制时看到的是它。
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text('校园地图'),
        actions: <Widget>[
          if (_embedding && _loadError == null)
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh),
              onPressed: _refresh,
            ),
        ],
      ),
      body: _embedding ? _buildEmbedded(colorScheme) : _buildUnavailable(colorScheme),
    );
  }

  Widget _buildEmbedded(ColorScheme colorScheme) {
    return Column(
      children: <Widget>[
        if (_loading && _loadError == null)
          LinearProgressIndicator(value: _progress > 0 ? _progress / 100 : null),
        if (_locationDenied) _buildLocationNotice(colorScheme),
        Expanded(
          child: Container(
            color: colorScheme.surface,
            child: Stack(
              children: <Widget>[
                WebViewWidget(controller: _controller!),
                // 加载中不要给用户一块纯白：盖一层说明 + 进度。
                // （作者 2026-11-09："白屏""每次打开都要等好久"）
                if (_loading && _loadError == null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: colorScheme.surface,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const SizedBox(
                              width: 26,
                              height: 26,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '正在加载校园地图…',
                              style: TextStyle(
                                fontSize: 14,
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _progress > 0
                                  ? '已加载 $_progress%'
                                  : '首次打开需要十几秒，之后会快很多',
                              style: TextStyle(
                                fontSize: 12,
                                color: colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.75),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                // 慢提示必须在"还在加载"时可见：_slowHint 由加载中的 15s 定时器置真，
                // 一旦加载结束 _onPageFinished/_onProgress 就会把它清掉。
                if (_slowHint && _loadError == null)
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Material(
                      color: colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(10),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                '地图加载较慢，可以稍等，或用浏览器打开',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: _openInBrowser,
                              child: const Text('浏览器打开'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_loadError != null)
                  Positioned.fill(
                    child: ColoredBox(
                      color: colorScheme.surface,
                      child: CampusMapMessageView(
                        icon: Icons.wifi_off,
                        title: '地图加载失败',
                        message: _loadError!,
                        primaryLabel: '重试',
                        onPrimary: () => _loadMap(force: true),
                        onSecondary: _openInBrowser,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 定位被拒时的常驻提示（不阻断浏览，比一次性 SnackBar 更有用）。
  Widget _buildLocationNotice(ColorScheme colorScheme) {
    return Container(
      width: double.infinity,
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: <Widget>[
          Icon(Icons.location_off_outlined, size: 18, color: colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '未授予定位权限：地图可以浏览，但无法定位到你的当前位置。',
              style: TextStyle(fontSize: 12, color: colorScheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: _requestLocationPermission,
            child: const Text('重新授权'),
          ),
        ],
      ),
    );
  }

  /// 当前平台没有 WebView 实现（Windows 桌面 / 插件未注册）时的降级页。
  Widget _buildUnavailable(ColorScheme colorScheme) {
    return CampusMapMessageView(
      icon: Icons.map_outlined,
      title: '校园地图由学校 GIS 站点提供',
      message: '当前平台不支持内嵌地图，请用系统浏览器打开。',
      primaryLabel: '用系统浏览器打开',
      onPrimary: _openInBrowser,
      secondaryLabel: '刷新',
      onSecondary: () {
        setState(() => _loadError = null);
        _loadMap();
      },
    );
  }
}

/// 居中提示视图：加载失败 / 平台不支持两种情况共用。
///
/// 之所以单独成类：错误态与降级态都能在**不依赖 WebView 平台实现**的前提下单测。
class CampusMapMessageView extends StatelessWidget {
  const CampusMapMessageView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 56, color: colorScheme.primary),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            if (primaryLabel != null || secondaryLabel != null) ...<Widget>[
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  if (primaryLabel != null)
                    FilledButton.icon(
                      onPressed: onPrimary,
                      icon: const Icon(Icons.open_in_new),
                      label: Text(primaryLabel!),
                    ),
                  if (secondaryLabel != null)
                    TextButton(
                      onPressed: onSecondary,
                      child: Text(secondaryLabel!),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
