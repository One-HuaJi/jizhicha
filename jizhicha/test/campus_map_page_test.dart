import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/campus_map_controller.dart';
import 'package:jizhicha/campus_map_page.dart';
import 'package:jizhicha/more_page.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 校园地图页 / 「更多」页的可单测部分。
///
/// 这里刻意**不注册任何 WebView 平台实现**（`WebViewPlatform.instance == null`），
/// 于是 `CampusMapPage` 走的是「平台不支持内嵌」的降级分支 —— 这条分支能在
/// `flutter test` 里跑，而真正的 WebView + 定位链路只能在真机上验证
/// （见交付说明里的「未验证项」）。
void main() {
  group('校园地图常量', () {
    test('站点地址是学校 GIS 高德 H5 首页', () {
      expect(campusMapUrl, 'https://gis.huse.edu.cn/cmipsh5/#/');
      expect(Uri.parse(campusMapUrl).scheme, 'https');
      expect(Uri.parse(campusMapUrl).host, 'gis.huse.edu.cn');
    });

    test('原生 Channel 名与白名单后缀固定', () {
      // 这两个字面量必须与 CampusMapGeolocation.kt 完全一致，写成断言防走样。
      expect(campusMapChannelName, 'com.one.huaji/campus_map');
      expect(campusMapHostSuffix, 'huse.edu.cn');
    });
  });

  group('CampusMapController（进程内复用 / 预热）', () {
    test('没有 WebView 平台时预热是安全空转', () async {
      // 测试环境 WebViewPlatform.instance == null，预热必须直接返回，
      // 不能去构造 WebViewController（那会抛 UnsupportedError）。
      await CampusMapController.instance.prewarm(campusMapUrl);
      expect(CampusMapController.instance.isLoaded, isFalse);
      expect(CampusMapController.instance.isLoading, isFalse);
    });

    test('空闲保留时间够长，切出去回来不重载', () {
      expect(
        CampusMapController.idleTtl >= const Duration(minutes: 20),
        isTrue,
        reason: '太短会退化成每次进来都从白屏重新加载',
      );
    });
  });

  group('isCampusMapHost', () {
    test('接受学校域名与子域（大小写无关）', () {
      expect(isCampusMapHost('huse.edu.cn'), isTrue);
      expect(isCampusMapHost('gis.huse.edu.cn'), isTrue);
      expect(isCampusMapHost('GIS.HUSE.EDU.CN'), isTrue);
    });

    test('拒绝伪装域名与空串', () {
      expect(isCampusMapHost(''), isFalse);
      expect(isCampusMapHost('evil-huse.edu.cn'), isFalse);
      expect(isCampusMapHost('huse.edu.cn.evil.com'), isFalse);
      expect(isCampusMapHost('huse.edu.cn.'), isFalse);
      expect(isCampusMapHost('example.com'), isFalse);
    });
  });

  group('isInAppNavigableUrl', () {
    test('放行 http/https 的学校地址', () {
      expect(isInAppNavigableUrl(campusMapUrl), isTrue);
      expect(isInAppNavigableUrl('http://gis.huse.edu.cn/cmipsh5/'), isTrue);
      expect(isInAppNavigableUrl('https://huse.edu.cn/'), isTrue);
    });

    test('站外与非常规 scheme 一律交给系统处理', () {
      expect(isInAppNavigableUrl('https://m.amap.com/navi'), isFalse);
      expect(isInAppNavigableUrl('https://gis.huse.edu.cn.evil.com/x'), isFalse);
      expect(isInAppNavigableUrl('intent://scan#Intent;scheme=zxing;end'), isFalse);
      expect(isInAppNavigableUrl('tel:1234567'), isFalse);
      expect(isInAppNavigableUrl('file:///data/local/tmp/a.txt'), isFalse);
      expect(isInAppNavigableUrl('http://[::1'), isFalse);
      expect(isInAppNavigableUrl(''), isFalse);
    });
  });

  group('CampusMapMessageView', () {
    testWidgets('渲染标题/说明/两个按钮，并回调各自动作', (tester) async {
      int primary = 0;
      int secondary = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CampusMapMessageView(
              icon: Icons.wifi_off,
              title: '地图加载失败',
              message: '请检查网络后重试',
              primaryLabel: '重试',
              onPrimary: () => primary++,
              secondaryLabel: '用系统浏览器打开',
              onSecondary: () => secondary++,
            ),
          ),
        ),
      );

      expect(find.text('地图加载失败'), findsOneWidget);
      expect(find.text('请检查网络后重试'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('用系统浏览器打开'), findsOneWidget);

      await tester.tap(find.text('重试'));
      await tester.tap(find.text('用系统浏览器打开'));
      await tester.pump();
      expect(primary, 1);
      expect(secondary, 1);
    });

    testWidgets('不传按钮文案时不渲染按钮区', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CampusMapMessageView(
              icon: Icons.map_outlined,
              title: '标题',
              message: '说明',
            ),
          ),
        ),
      );
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
    });
  });

  group('CampusMapPage', () {
    testWidgets('无 WebView 平台实现时降级为外链引导，且不建 WebView', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: CampusMapPage()));

      expect(find.text('校园地图'), findsOneWidget);
      expect(find.text('校园地图由学校 GIS 站点提供'), findsOneWidget);
      expect(find.text('用系统浏览器打开'), findsOneWidget);
      // 桌面/单测环境没有平台实现：不能出现 WebView，也不能出现加载指示。
      expect(find.byType(WebViewWidget), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      // 降级页的「刷新」不能因为 controller 为空而崩。
      await tester.tap(find.text('刷新'));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('页面底色跟随主题（深色主题下不铺白底）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const CampusMapPage(),
        ),
      );
      final Scaffold scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, ThemeData.dark().colorScheme.surface);
      expect(scaffold.backgroundColor, isNot(Colors.white));
    });
  });

  group('MorePage', () {
    testWidgets('不再有「小组件（测试）」入口', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MorePage()));
      expect(find.text('小组件（测试）'), findsNothing);
      // 正式功能入口仍然在（只删了「更多」里的入口，页面本身没动）。
      expect(find.text('体测计算器'), findsOneWidget);
      expect(find.text('综测计算器'), findsOneWidget);
      expect(find.text('校园地图'), findsOneWidget);
    });

    testWidgets('点「校园地图」走应用内页面（不再直接跳外链）', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: MorePage()));
      await tester.tap(find.text('校园地图'));
      await tester.pumpAndSettle();
      expect(find.byType(CampusMapPage), findsOneWidget);
    });
  });
}
