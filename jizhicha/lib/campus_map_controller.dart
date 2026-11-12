import 'package:webview_flutter/webview_flutter.dart';

/// 进程内共享的校园地图 WebView 控制器。
///
/// 为什么要有它（作者 2026-11-09：「每次打开都要等好久，能不能打开一次后本地保存」）：
/// 校园地图是学校的高德 H5，首屏要拉 `config.js` + 高德 JS SDK（几百 KB）+ 一堆地图瓦片，
/// 而站点首页**不带任何 Cache-Control / ETag**（`curl -sI` 只有 `HTTP/1.1 200 OK`），
/// 浏览器只能靠启发式缓存，经常等于每次重下。
/// 更糟的是原来每进一次页面就 `WebViewController()` 新建一个 WebView（`dispose` 里置 null），
/// 等于每次都从白屏开始 —— 上次已经解码好的页面、已下载的资源、地图的缩放位置全丢。
///
/// 这里改成**进程内复用同一个控制器**：
///   * 第一次打开：正常加载；
///   * 退出页面：只 detach（`WebViewWidget` 不再挂载），控制器与页面留在内存；
///   * 再次打开：直接挂回去，看到的就是上次那张图，**不再重新 load**；
///   * 空闲超过 [idleTtl] 才真正释放，避免长期占用内存。
///
/// 注意：一个 `WebViewController` 同一时刻只能挂在一个 `WebViewWidget` 上，
/// 所以必须保证页面是**串行**打开的（本 App 只有「更多 → 校园地图」一个入口）。
class CampusMapController {
  CampusMapController._();

  static final CampusMapController instance = CampusMapController._();

  /// 空闲多久后释放（分钟）。太短会退化成每次重载，太长占内存。
  static const Duration idleTtl = Duration(minutes: 10);

  WebViewController? _controller;
  DateTime? _lastUsedAt;
  String? _loadedUrl;

  /// 当前是否已经加载过页面（用于判断「能不能直接复用」）。
  bool get isLoaded => _loadedUrl != null;

  /// 取控制器；没有或已过空闲期就新建。
  WebViewController obtain(String url) {
    disposeIfIdle();
    _lastUsedAt = DateTime.now();
    final WebViewController? existing = _controller;
    if (existing != null) return existing;
    final WebViewController created = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    _controller = created;
    _loadedUrl = null;
    return created;
  }

  /// 页面加载完成时登记（由页面在 `onPageFinished` 里调用）。
  void markLoaded(String url) {
    _loadedUrl = url;
    _lastUsedAt = DateTime.now();
  }

  /// 页面退出时调用：只记录使用时间，不销毁。
  void release() {
    _lastUsedAt = DateTime.now();
  }

  /// 空闲超时才真正释放。
  void disposeIfIdle() {
    final DateTime? last = _lastUsedAt;
    if (last == null) return;
    if (DateTime.now().difference(last) < idleTtl) return;
    _controller = null;
    _loadedUrl = null;
    _lastUsedAt = null;
  }
}
