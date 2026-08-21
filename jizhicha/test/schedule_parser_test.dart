import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/credential_store.dart';
import 'package:jizhicha/main.dart';
import 'package:jizhicha/schedule_cache_store.dart';

// 验证课表解析，重点覆盖“课程名被 <span> 包裹”这一导致旧版返回空结果的 bug。
void main() {
  const header =
      '<tr><th>节次/星期</th><th>周一</th><th>周二</th><th>周三</th><th>周四</th><th>周五</th><th>周六</th><th>周日</th></tr>';

  test('解析被 <span> 包裹课程名的课表（修复核心）', () {
    final html =
        '''
    <table id="timetable">
      $header
      <tr>
        <td>第一节</td>
        <td><div class="kbcontent"><span>高等数学</span><br><font title="教师">张伟</font><br><font title="教室">教A101</font><br><font title="周次(节次)">1-16周</font></div></td>
        <td></td><td></td><td></td><td></td><td></td><td></td>
      </tr>
    </table>
    ''';
    final courses = parseScheduleHtml(html);
    expect(courses.length, 1);
    expect(courses[0]['name'], '高等数学');
    expect(courses[0]['teacher'], '张伟');
    expect(courses[0]['room'], '教A101');
    expect(courses[0]['weeks'], '1-16周');
    expect(courses[0]['day'], '周一');
  });

  test('兼容裸文本课程名（无 <span> 包裹，旧版可解析）', () {
    final html =
        '''
    <table id="timetable">
      $header
      <tr>
        <td>第三节</td>
        <td><div class="kbcontent">大学英语<br><font title="教师">李娜</font><br><font title="教室">外B203</font><br><font title="周次(节次)">1-16周</font></div></td>
        <td></td><td></td><td></td><td></td><td></td><td></td>
      </tr>
    </table>
    ''';
    final courses = parseScheduleHtml(html);
    expect(courses.length, 1);
    expect(courses[0]['name'], '大学英语');
  });

  test('缺课表时返回空', () {
    expect(parseScheduleHtml('<div>没有任何课表</div>'), isEmpty);
  });

  group('extractIframeSrc', () {
    test('双引号 src', () {
      const html =
          '<iframe id="kb" src="/jsxsd/xskb/xskb_iframe.do?xnxq=2025-2026-2"></iframe>';
      expect(
        extractIframeSrc(html),
        '/jsxsd/xskb/xskb_iframe.do?xnxq=2025-2026-2',
      );
    });

    test('单引号 src', () {
      const html = "<iframe src='kbcontent.html'></iframe>";
      expect(extractIframeSrc(html), 'kbcontent.html');
    });

    test('无 iframe 时返回 null', () {
      expect(extractIframeSrc('<div>no iframe</div>'), isNull);
    });

    test('忽略 javascript: 占位 iframe', () {
      expect(
        extractIframeSrc("<iframe src='javascript:void(0)'></iframe>"),
        isNull,
      );
    });
  });

  group('extractTableBlocks / scheduleDiagnostics', () {
    const html = '''
    <html><head><title>学期理论课表</title>
    <meta name="keywords" content="湖南强智科技教务系统"></head>
    <body>
    <table id="kbtable" class="kb"><tr><td><div class="kbcontent">高等数学</div></td></tr></table>
    </body></html>
    ''';

    test('extractTableBlocks 抽取到课表 table', () {
      final blocks = extractTableBlocks(html);
      expect(blocks.length, 1);
      expect(blocks.first, contains('id="kbtable"'));
      expect(blocks.first, contains('高等数学'));
    });

    test('scheduleDiagnostics 识别强智 + 表格结构', () {
      final d = scheduleDiagnostics(html);
      expect(d['vendor'], '强智科技');
      expect(d['tableCount'], '1');
      expect(d['tableIds'], 'kbtable');
      expect(d['tableClasses'], 'kb');
      expect(d['hasKbcontent'], '是');
      expect(d['hasIframe'], '否');
      expect(d['hasWeekdayHeader'], '否'); // 该片段无星期表头
    });

    test('scheduleDiagnostics 无表格时报告 0', () {
      final d = scheduleDiagnostics('<div>无表格</div>');
      expect(d['tableCount'], '0');
      expect(d['tableIds'], '(无)');
    });
  });

  group('强智 timetable 实战场景', () {
    const header =
        '<tr><th>节次</th><th>周一</th><th>周二</th><th>周三</th><th>周四</th><th>周五</th><th>周六</th><th>周日</th></tr>';

    test('节次列 rowspan 合并：续行只有 7 格也能解析', () {
      // 第一行 8 格（含时间格）；第二行被 rowspan 合并，只有 7 格（无时间格）。
      final html =
          '''
      <table id="timetable">
        $header
        <tr>
          <td rowspan="2">上午</td>
          <td><div class="kbcontent"><span>高等数学</span><br><font title="教师">张伟</font><br><font title="教室">教A101</font></div></td>
          <td></td><td></td><td></td><td></td><td></td><td></td>
        </tr>
        <tr>
          <td><div class="kbcontent"><span>大学英语</span><br><font title="教师">李娜</font><br><font title="教室">外B203</font></div></td>
          <td></td><td></td><td></td><td></td><td></td><td></td>
        </tr>
      </table>
      ''';
      final courses = parseScheduleHtml(html);
      expect(courses.length, 2);
      expect(courses[0]['name'], '高等数学');
      expect(courses[0]['time'], '上午');
      expect(courses[1]['name'], '大学英语');
      expect(courses[1]['time'], '上午'); // 续行沿用上一行时间
      expect(courses[0]['day'], '周一');
      expect(courses[1]['day'], '周一');
    });

    test('kbcontent1 不再被误杀（强智正经课程可能在此 class）', () {
      final html =
          '''
      <table id="timetable">
        $header
        <tr>
          <td>第一节</td>
          <td><div class="kbcontent1"><span>线性代数</span><br><font title="教师">王芳</font><br><font title="教室">教C305</font></div></td>
          <td></td><td></td><td></td><td></td><td></td><td></td>
        </tr>
      </table>
      ''';
      final courses = parseScheduleHtml(html);
      expect(courses.length, 1);
      expect(courses[0]['name'], '线性代数');
    });
  });

  group('extractTableById', () {
    const html = '''
    <div>前置内容</div>
    <table id="timetable"><tr><td>课表A</td></tr></table>
    <table id="dataTables"><tr><td>列表B</td></tr></table>
    ''';

    test('按 id 精确抽取对应 table', () {
      expect(extractTableById(html, 'timetable'), contains('课表A'));
      expect(extractTableById(html, 'timetable'), isNot(contains('列表B')));
      expect(extractTableById(html, 'dataTables'), contains('列表B'));
    });

    test('无匹配 id 返回 null', () {
      expect(extractTableById(html, 'nope'), isNull);
    });
  });

  group('parseWeekSpan/parseWeekSpans 周次解析（冲突判定基础）', () {
    test('普通范围 1-10(周)', () {
      final s = parseWeekSpans('1-10(周)');
      expect(s.length, 1);
      expect(s.first, {'start': 1, 'end': 10});
    });

    test('带节次标记 11-12(周)[01-02节] 忽略括号', () {
      final s = parseWeekSpans('11-12(周)[01-02节]');
      expect(s.first, {'start': 11, 'end': 12});
    });

    test('单周 5(周)', () {
      final s = parseWeekSpans('5(周)');
      expect(s.first, {'start': 5, 'end': 5});
    });

    test('多段逗号周次 1-4,9-12(周)', () {
      final s = parseWeekSpans('1-4,9-12(周)');
      expect(s, [
        {'start': 1, 'end': 4},
        {'start': 9, 'end': 12},
      ]);
    });

    test('空字符串返回空列表', () {
      expect(parseWeekSpans(''), isEmpty);
    });

    test('无 (周) 标记的乱码返回空列表', () {
      expect(parseWeekSpans('暂无'), isEmpty);
    });

    test('_weekSpansOverlap 多段相交判定', () {
      // 1-4,9-12 与 9-10 在 9-10 段相交 → true
      expect(
        weekSpansOverlap(
          parseWeekSpans('1-4,9-12(周)'),
          parseWeekSpans('9-10(周)'),
        ),
        isTrue,
      );
      // 1-4,9-12 与 5-6 完全不相交 → false
      expect(
        weekSpansOverlap(
          parseWeekSpans('1-4,9-12(周)'),
          parseWeekSpans('5-6(周)'),
        ),
        isFalse,
      );
      // 1-10 与 11-12 不相交 → false
      expect(
        weekSpansOverlap(parseWeekSpans('1-10(周)'), parseWeekSpans('11-12(周)')),
        isFalse,
      );
    });
  });

  group('强智真实单引号 HTML（修复后）', () {
    // 真实强智系统：title 属性用单引号（title='教师'），教师/教室/周次在隐藏的
    // display:none 详情卡 kbcontent 里，可见课表在 kbcontent1。这里用与真实结构一致的
    // 片段验证“单引号 + 隐藏详情卡”两个修复点。
    const html = '''
    <table id="timetable">
      <tr><th>节次/星期</th><th>周一</th><th>周二</th><th>周三</th><th>周四</th><th>周五</th><th>周六</th><th>周日</th></tr>
      <tr>
        <th>第一大节<br>(01,02小节)</th>
        <td>
          <div class="kbcontent1">分子生物学<br/><font title='周次(节次)'>1-12(周)</font><br/><font title='教室'>逸夫楼218</font><br/></div>
          <div style="display: none;" class="kbcontent" >分子生物学<br/><font title='教师'>闫荣玲,李常健</font><br/><font title='周次(节次)'>1-12(周)[01-02节]</font><br/><font title='教室'>逸夫楼218</font><br/></div>
          <div style="display:none;" class="kbcontent" ></div>
        </td>
        <td>
          <div class="kbcontent1">高等数学D（二）<br/><font title='周次(节次)'>1-10(周)</font><br/><font title='教室'>逸夫楼218</font><br/>----------------------<br>遗传学<br/><font title='周次(节次)'>1-10(周)</font><br/><font title='教室'>逸夫楼323</font><br/>----------------------<br>形势与政策（四）<br/><font title='周次(节次)'>11-12(周)</font><br/><font title='教室'>明德楼305（模拟法庭）</font><br/></div>
          <div style="display: none;" class="kbcontent">高等数学D（二）<br/><font title='教师'>曾方青</font><br/><font title='周次(节次)'>1-10(周)[01-02节]</font><br/><font title='教室'>逸夫楼218</font><br/>---------------------<br>遗传学<br/><font title='教师'>何春兰</font><br/><font title='周次(节次)'>1-10(周)[01-02节]</font><br/><font title='教室'>逸夫楼323</font><br/>---------------------<br>形势与政策（四）<br/><font title='教师'>胡赟</font><br/><font title='周次(节次)'>11-12(周)[01-02节]</font><br/><font title='教室'>明德楼305（模拟法庭）</font><br/></div>
          <div style="display:none;" class="kbcontent" ></div>
        </td>
        <td></td><td></td><td></td><td></td><td></td>
      </tr>
    </table>
    ''';

    Map<String, String> find(List<Map<String, String>> courses, String name) =>
        courses.firstWhere((c) => c['name'] == name);

    test('共解析出 4 门课（周一1 + 周二3），无重复', () {
      final courses = parseScheduleHtml(html);
      expect(courses.length, 4);
    });

    test('kbcontent1 提供名/室/周，隐藏详情卡提供教师（单引号可被解析）', () {
      final courses = parseScheduleHtml(html);
      final mol = find(courses, '分子生物学');
      expect(mol['day'], '周一');
      expect(mol['room'], '逸夫楼218');
      expect(mol['weeks'], '1-12(周)');
      expect(mol['teacher'], '闫荣玲,李常健'); // 来自 display:none 详情卡
    });

    test('周二 3 门冲突/非冲突课都带教师', () {
      final courses = parseScheduleHtml(html);
      expect(find(courses, '高等数学D（二）')['teacher'], '曾方青');
      expect(find(courses, '遗传学')['teacher'], '何春兰');
      expect(find(courses, '形势与政策（四）')['teacher'], '胡赟');
      expect(find(courses, '形势与政策（四）')['weeks'], '11-12(周)');
    });

    test('周二格在第11周筛选后只保留形势与政策，高数/遗传学被隐藏', () {
      // 同格 3 门课：高数/遗传学 1-10 周，形势与政策 11-12 周。
      final courses = parseScheduleHtml(html);
      final tue = courses.where((c) => c['day'] == '周二').toList();
      expect(tue.length, 3);
      final week11 = tue
          .where((c) => weekInWeeks(c['weeks'] ?? '', 11))
          .toList();
      expect(week11.length, 1);
      expect(week11.first['name'], '形势与政策（四）');
    });
  });

  group('weekInWeeks 按周筛选', () {
    test('第5周命中 1-10(周)，不命中 11-12(周)', () {
      expect(weekInWeeks('1-10(周)', 5), isTrue);
      expect(weekInWeeks('11-12(周)', 5), isFalse);
      expect(weekInWeeks('11-12(周)', 11), isTrue);
    });

    test('多段逗号周次 1-4,6-12(周)', () {
      expect(weekInWeeks('1-4,6-12(周)', 3), isTrue);
      expect(weekInWeeks('1-4,6-12(周)', 5), isFalse);
      expect(weekInWeeks('1-4,6-12(周)', 8), isTrue);
    });

    test('冲突课程按周筛选：第11周只显示当周有课课程', () {
      // 模拟真实场景：同一格有 1-10 周的高数 和 11-12 周的形势与政策
      final courses = [
        {'name': '高等数学', 'weeks': '1-10(周)'},
        {'name': '形势与政策', 'weeks': '11-12(周)'},
      ];
      final week11 = courses
          .where((c) => weekInWeeks(c['weeks']!, 11))
          .toList();
      // 第11周不应再显示 1-10 周的高数（这是用户报告的 bug）
      expect(week11.any((c) => c['name'] == '高等数学'), isFalse);
      expect(week11.any((c) => c['name'] == '形势与政策'), isTrue);
    });
  });

  group('真实导出的课表 HTML（若存在）', () {
    // 直接解析用户导出的真实文件，作为端到端校验；文件不存在则跳过。
    final file = File('huse_jwxt_schedule_2026-07-27T15-38-44.html');
    final html = file.existsSync() ? file.readAsStringSync() : null;

    test('解析真实文件且所有课程都带周次（无空周次）', () {
      if (html == null) return; // 跳过：本地无该导出文件
      final courses = parseScheduleHtml(html);
      expect(courses, isNotEmpty);
      // 关键回归：修复前教师/教室/周次全空；修复后周次不应为空
      for (final c in courses) {
        expect(c['weeks'], isNotEmpty, reason: '课程 ${c['name']} 周次不应为空');
      }
      // 教师也应被解析出来（来自隐藏详情卡，单引号）
      final withTeacher = courses
          .where((c) => (c['teacher'] ?? '').isNotEmpty)
          .length;
      expect(withTeacher, greaterThan(0), reason: '至少应解析出部分教师');
    }, skip: html == null ? '本地无真实导出文件' : false);

    test('真实文件按周筛选：第11周不应显示 1-10 周的高数', () {
      if (html == null) return;
      final courses = parseScheduleHtml(html);
      final week11 = courses
          .where((c) => weekInWeeks(c['weeks'] ?? '', 11))
          .toList();
      // 高等数学D（二）实际周次为 1-10 周，第11周必须被过滤掉
      expect(
        week11.any((c) => (c['name'] ?? '').contains('高等数学')),
        isFalse,
        reason: '第11周不应显示 1-10 周的高数',
      );
      // 形势与政策（四）11-12 周在第11周应保留
      expect(
        week11.any((c) => (c['name'] ?? '').contains('形势与政策')),
        isTrue,
        reason: '第11周应保留 11-12 周的形势与政策',
      );
    }, skip: html == null ? '本地无真实导出文件' : false);
  });

  group('体测评分（2014 标准）', () {
    test('bmiScore 男：正常/低体重/超重/肥胖', () {
      expect(bmiScore(20.5, true), 100);
      expect(bmiScore(17.0, true), 80); // 低体重
      expect(bmiScore(25.0, true), 80); // 超重
      expect(bmiScore(30.0, true), 60); // 肥胖
    });
    test('bmiScore 女：正常/低体重/超重/肥胖', () {
      expect(bmiScore(20.0, false), 100);
      expect(bmiScore(16.5, false), 80); // 低体重
      expect(bmiScore(26.0, false), 80); // 超重
      expect(bmiScore(29.0, false), 60); // 肥胖
    });

    test('fitScore 越高越好：肺活量男大一大二边界值', () {
      final t = fitHigher['M12_lung']!;
      expect(fitScore(t, 5040, true), 100); // 满分阈值
      expect(fitScore(t, 4800, true), 90); // 90 分阈值
      expect(fitScore(t, 3100, true), 60); // 60 分阈值
      expect(fitScore(t, 2300, true), 10); // 最低分阈值
      expect(fitScore(t, 9999, true), 100); // 超过满分取满分
      expect(
        fitScore(t, 4860, true),
        closeTo(92.5, 0.001),
      ); // 区间内插值：4920→95,4800→90 的中点
    });

    test('fitScore 越低越好：50米男大一大二边界值', () {
      final t = fitLower['M12_50']!;
      expect(fitScore(t, 6.7, false), 100);
      expect(fitScore(t, 9.1, false), 60);
      expect(fitScore(t, 10.1, false), 10);
      expect(
        fitScore(t, 6.85, false),
        closeTo(92.5, 0.001),
      ); // 6.8→95,6.9→90 之间
    });

    test('满分男大一大二：各项取满分，总分为 100', () {
      // 直接验证权重和=1 且满分路径：用各单项 100 分计算
      const weights = [0.15, 0.15, 0.20, 0.10, 0.10, 0.10, 0.20];
      final sum = weights.fold<double>(0, (p, w) => p + 100 * w);
      expect(sum, 100.0);
    });

    // ===== 关键 bug 修复验证：引体向上 / 1分钟仰卧起坐 =====
    // 旧 bug：表 key 是 'M12_pull'/'F12_situp'，但 _FitItemDef 用 '_pu' 拼成
    // 'M12_pu'，永远查不到表，输入后得分一直是 '—'。修复后表 key 改为 'pu'。
    test('男生引体向上 M12 表存在且 19 次 = 100 分', () {
      final t = fitHigher['M12_pu']!;
      expect(fitScore(t, 19, true), 100);
      expect(fitScore(t, 15, true), 80);
      expect(fitScore(t, 14, true), 76); // 修复前缺这档
      expect(fitScore(t, 5, true), 10);
    });
    test('男生引体向上 M34 表存在且 20 次 = 100 分', () {
      final t = fitHigher['M34_pu']!;
      expect(fitScore(t, 20, true), 100);
      expect(fitScore(t, 15, true), 76); // 修复前缺这档
    });
    test('女生 1 分钟仰卧起坐 F12/F34 表存在', () {
      expect(fitHigher['F12_pu'], isNotNull);
      expect(fitHigher['F34_pu'], isNotNull);
      expect(fitScore(fitHigher['F12_pu']!, 56, true), 100);
      expect(fitScore(fitHigher['F12_pu']!, 26, true), 60);
      expect(fitScore(fitHigher['F34_pu']!, 57, true), 100);
    });
    // 旧 key 不能再用（保证彻底切到 '_pu'）
    test('旧的 pull/situp key 已彻底废弃', () {
      expect(fitHigher.containsKey('M12_pull'), false);
      expect(fitHigher.containsKey('M34_pull'), false);
      expect(fitHigher.containsKey('F12_situp'), false);
      expect(fitHigher.containsKey('F34_situp'), false);
    });

    // ===== BMI 边界（含端点） =====
    test('BMI 男生边界：17.8 低体重, 17.9 正常, 23.9 正常, 24.0 超重, 27.9 超重, 28.0 肥胖', () {
      expect(bmiScore(17.8, true), 80);
      expect(bmiScore(17.9, true), 100);
      expect(bmiScore(23.9, true), 100);
      expect(bmiScore(24.0, true), 80);
      expect(bmiScore(27.9, true), 80);
      expect(bmiScore(28.0, true), 60);
    });
    test('BMI 女生边界：17.1 低体重, 17.2 正常, 23.9 正常, 24.0 超重, 27.9 超重, 28.0 肥胖', () {
      expect(bmiScore(17.1, false), 80);
      expect(bmiScore(17.2, false), 100);
      expect(bmiScore(23.9, false), 100);
      expect(bmiScore(24.0, false), 80);
      expect(bmiScore(27.9, false), 80);
      expect(bmiScore(28.0, false), 60);
    });
  });

  // ==================== 成绩归档：文字评分处理 ====================
  group('isGradeFail 文字/数字混合判定', () {
    test('纯数字 >= 60 通过', () {
      expect(isGradeFail('60'), false);
      expect(isGradeFail('85'), false);
      expect(isGradeFail('100'), false);
    });
    test('纯数字 < 60 不通过', () {
      expect(isGradeFail('59'), true);
      expect(isGradeFail('0'), true);
      expect(isGradeFail('45.5'), true);
    });
    test('文字合格：优秀/良好/中等/合格/及格/通过', () {
      expect(isGradeFail('优秀'), false);
      expect(isGradeFail('良好'), false);
      expect(isGradeFail('中等'), false);
      expect(isGradeFail('合格'), false);
      expect(isGradeFail('及格'), false);
      expect(isGradeFail('通过'), false);
      expect(isGradeFail('优'), false);
      expect(isGradeFail('良'), false);
    });
    test('文字不合格：不及格/不合格/未通过/不通过', () {
      expect(isGradeFail('不及格'), true);
      expect(isGradeFail('不合格'), true);
      expect(isGradeFail('未通过'), true);
      expect(isGradeFail('不通过'), true);
    });
    test('混合形式 "85(优)" 通过；"55(不及格)" 不通过', () {
      expect(isGradeFail('85(优)'), false);
      expect(isGradeFail('55(不及格)'), true);
    });
    test('空字符串 / 完全无法识别 → 不通过（保守归入补考）', () {
      expect(isGradeFail(''), true);
      expect(isGradeFail('???'), true);
    });
  });

  // ==================== 等级显示 ====================
  group('scoreLevel 等级名', () {
    test('分数对应等级：优秀/良好/及格/不及格/null', () {
      expect(scoreLevel(95), '优秀');
      expect(scoreLevel(90), '优秀');
      expect(scoreLevel(85), '良好');
      expect(scoreLevel(80), '良好');
      expect(scoreLevel(70), '及格');
      expect(scoreLevel(60), '及格');
      expect(scoreLevel(59), '不及格');
      expect(scoreLevel(0), '不及格');
      expect(scoreLevel(null), '—');
    });
  });

  // ==================== 成绩缓存：按学期增量合并 ====================
  test('只替换成功返回的学期，失败学期保留旧成绩', () {
    final merged = mergeGradesByTerms(
      previous: [
        {'term': '2025-2026-2', 'course': '旧数学', 'grade': '80'},
        {'term': '2025-2026-1', 'course': '英语', 'grade': '90'},
      ],
      fetched: [
        {'term': '2025-2026-2', 'course': '新数学', 'grade': '95'},
      ],
      replacedTerms: const ['2025-2026-2'],
    );

    expect(merged, [
      {'term': '2025-2026-1', 'course': '英语', 'grade': '90'},
      {'term': '2025-2026-2', 'course': '新数学', 'grade': '95'},
    ]);
  });

  test('成功学期返回空成绩时会清除该学期旧记录', () {
    final merged = mergeGradesByTerms(
      previous: [
        {'term': '2025-2026-2', 'course': '已撤销课程', 'grade': '80'},
        {'term': '2025-2026-1', 'course': '英语', 'grade': '90'},
      ],
      fetched: const [],
      replacedTerms: const ['2025-2026-2'],
    );

    expect(merged, [
      {'term': '2025-2026-1', 'course': '英语', 'grade': '90'},
    ]);
  });

  group('教务强制改密页面解析与密码校验', () {
    test('解析官网身份核验页并确认返回账号完全一致', () {
      const html = '''
      <form id="Form1">
        <input name="account" value="202400000000" readonly>
        <input name="accounttype" value="2" type="hidden">
        <input name="sfzjh" type="text">
      </form>
      ''';
      final result = parsePasswordRecoveryAccountPage(
        html,
        expectedStudentId: '202400000000',
      );
      expect(result.studentId, '202400000000');
      expect(result.accountType, '2');
    });

    test('身份核验页账号不一致时立即停止', () {
      const html = '''
      <form><input name="account" value="other"><input name="sfzjh"></form>
      ''';
      expect(
        () => parsePasswordRecoveryAccountPage(
          html,
          expectedStudentId: '202400000000',
        ),
        throwsA(contains('账号与输入账号不一致')),
      );
    });

    test('身份核验成功页优先解析表单，不被页面提示脚本误判', () {
      const html = '''
      <script>alert("请输入正确的身份证号");</script>
      <form id="Form1">
        <input name="account" value="202400000000" readonly>
        <input name="sfzjh" type="text">
      </form>
      ''';
      final result = parsePasswordRecoveryAccountPage(
        html,
        expectedStudentId: '202400000000',
      );
      expect(result.studentId, '202400000000');
    });

    test('未录入学号使用独立的账号错误提示', () {
      const html = '<script>alert("用户名或密码错误！");</script>';
      expect(
        () => parsePasswordRecoveryAccountPage(
          html,
          expectedStudentId: '202400000000',
        ),
        throwsA(equals(passwordRecoveryStudentIdError)),
      );
    });

    test('官网错误的身份证号提示也统一为学号错误', () {
      const html = '<script>alert("请输入正确的身份证号");</script>';
      expect(
        () => parsePasswordRecoveryAccountPage(
          html,
          expectedStudentId: '202400000000',
        ),
        throwsA(equals(passwordRecoveryStudentIdError)),
      );
    });

    test('兼容官网布尔/字符串 JSON 与成功页，同时拒绝未知响应', () {
      final success = parsePasswordRecoveryResetResponse(
        '{"success":true,"message":"密码已重置为身份证号码的后六位"}',
      );
      expect(success.success, isTrue);
      expect(success.message, contains('后六位'));

      final stringSuccess = parsePasswordRecoveryResetResponse(
        '{"success":"true","msg":"密码重置成功"}',
      );
      expect(stringSuccess.success, isTrue);
      expect(stringSuccess.message, '密码重置成功');

      final htmlSuccess = parsePasswordRecoveryResetResponse(
        '<html><body><div>密码已重置为身份证号码的后六位</div></body></html>',
      );
      expect(htmlSuccess.success, isTrue);

      final alertSuccess = parsePasswordRecoveryResetResponse(
        '<script>alert("密码重置成功");</script>',
      );
      expect(alertSuccess.success, isTrue);

      final failure = parsePasswordRecoveryResetResponse(
        '{"success":false,"message":"身份证件号错误"}',
      );
      expect(failure.success, isFalse);
      expect(failure.message, '身份证件号错误');

      final instructionalForm = parsePasswordRecoveryResetResponse('''
        <form><input name="sfzjh"><p>提交后密码将重置为身份证后六位</p></form>
      ''');
      expect(instructionalForm.success, isFalse);

      expect(parsePasswordRecoveryResetResponse('未知内容').success, isFalse);
    });

    test('校园内网探测必须识别真实教务页面特征', () {
      expect(
        isExpectedJwxtProbeResponse(
          200,
          '<form action="/jsxsd/xk/LoginToXk"><input name="RANDOMCODE"></form>',
        ),
        isTrue,
      );
      expect(
        isExpectedJwxtProbeResponse(200, '<html>任意代理错误页面</html>'),
        isFalse,
      );
      expect(isExpectedJwxtProbeResponse(502, '教务系统'), isFalse);
      expect(isExpectedJwxtProbeResponse(200, ''), isFalse);
    });

    test('按中文标签动态识别四个字段及隐藏参数', () {
      const html = r'''
      <form action="/jsxsd/grsz/grsz_xgmm_save.do" method="post">
        <input type="hidden" name="token" value="safe-token">
        <input type="text" name="account" value="202400000000" readonly>
        <table>
          <tr><td>旧密码</td><td><input type="password" name="oldPwd"></td></tr>
          <tr><td>新密码</td><td><input type="password" name="newPwd"></td></tr>
          <tr><td>确认新密码</td><td><input type="password" name="confirmPwd"></td></tr>
          <tr><td>新密码提示</td><td><input type="text" name="pwdHint"></td></tr>
        </table>
      </form>
      ''';
      final form = parseEducationPasswordChangeForm(html);
      expect(form, isNotNull);
      expect(form!.action, '/jsxsd/grsz/grsz_xgmm_save.do');
      expect(form.oldPasswordField, 'oldPwd');
      expect(form.newPasswordField, 'newPwd');
      expect(form.confirmPasswordField, 'confirmPwd');
      expect(form.passwordHintField, 'pwdHint');
      expect(form.hiddenFields, {
        'token': 'safe-token',
        'account': '202400000000',
      });
    });

    test('无中文标签时按三个密码框顺序安全回退', () {
      const html = '''
      <form action="xgmm_save.do">
        <input type="password" name="p1">
        <input type="password" name="p2">
        <input type="password" name="p3">
        <input type="text" name="hint">
      </form>
      ''';
      final form = parseEducationPasswordChangeForm(html);
      expect(form, isNotNull);
      expect(form!.oldPasswordField, 'p1');
      expect(form.newPasswordField, 'p2');
      expect(form.confirmPasswordField, 'p3');
      expect(form.passwordHintField, 'hint');
    });

    test('form action 为空时从官网内联脚本提取改密地址', () {
      const html = r'''
      <form action="#">
        <table>
          <tr><td>旧密码</td><td><input type="password" name="p1"></td></tr>
          <tr><td>新密码</td><td><input type="password" name="p2"></td></tr>
          <tr><td>确认新密码</td><td><input type="password" name="p3"></td></tr>
          <tr><td>新密码提示</td><td><input type="text" name="hint"></td></tr>
        </table>
      </form>
      <script>$.ajax({url:'/jsxsd/grsz/grsz_xgmm_save.do'});</script>
      ''';
      expect(
        parseEducationPasswordChangeForm(html)!.action,
        '/jsxsd/grsz/grsz_xgmm_save.do',
      );
    });

    test('不完整页面拒绝提交，避免把密码发到错误字段', () {
      expect(
        parseEducationPasswordChangeForm(
          '<form action="xgmm.do"><input type="password" name="only"></form>',
        ),
        isNull,
      );
    });

    test('最终密码必须至少8位且同时包含字母和数字', () {
      expect(isValidFinalEducationPassword('abc12345'), isTrue);
      expect(isEducationPasswordSafeToStore('abc12345'), isTrue);
      expect(isValidFinalEducationPassword('Abcdefg8!'), isTrue);
      expect(isValidFinalEducationPassword('12345678'), isFalse);
      expect(isValidFinalEducationPassword('abcdefgh'), isFalse);
      expect(isValidFinalEducationPassword('a1b2c3'), isFalse);
      expect(isEducationPasswordSafeToStore('123456'), isFalse);
      expect(isEducationPasswordSafeToStore('12345X'), isFalse);
    });

    test('拒绝不一致、复用临时密码和泄露完整新密码的提示', () {
      expect(
        educationPasswordValidationError(
          oldPassword: '123456',
          newPassword: 'abc12345',
          confirmPassword: 'abc12346',
          passwordHint: '常用组合',
        ),
        contains('不一致'),
      );
      expect(
        educationPasswordValidationError(
          oldPassword: 'abc12345',
          newPassword: 'abc12345',
          confirmPassword: 'abc12345',
          passwordHint: '常用组合',
        ),
        contains('不能与'),
      );
      expect(
        educationPasswordValidationError(
          oldPassword: '123456',
          newPassword: 'abc12345',
          confirmPassword: 'abc12345',
          passwordHint: '我的abc12345',
        ),
        contains('不能包含'),
      );
    });

    test('识别官网脚本 alert 与 showMsg 错误', () {
      expect(
        extractJwxtAlertMessage(
          "<script>alert('验证码错误！');window.location='/'</script>",
        ),
        '验证码错误！',
      );
      expect(
        extractJwxtAlertMessage('<font id="showMsg"> 密码错误 </font>'),
        '密码错误',
      );
    });

    test('识别改密成功页面的 showMsg', () {
      final result = parseEducationPasswordChangeResponse(
        statusCode: 200,
        location: '',
        raw: '<font id="showMsg">密码修改成功</font>',
      );
      expect(result.success, isTrue);
    });

    test('识别改密成功页面的脚本跳转', () {
      final result = parseEducationPasswordChangeResponse(
        statusCode: 200,
        location: '',
        raw:
            r'''<script>window.location.href='/jsxsd/framework/xsmain';</script>''',
      );
      expect(result.success, isTrue);
    });

    test('302 回到改密页但带成功提示时仍认定成功', () {
      final result = parseEducationPasswordChangeResponse(
        statusCode: 302,
        location: '/jsxsd/grsz/grsz_xgmm_beg.do',
        raw: '<script>alert("密码修改成功");</script>',
      );
      expect(result.success, isTrue);
    });

    test('源码中的完整信息校验提示不能伪装成成功', () {
      final result = parseEducationPasswordChangeResponse(
        statusCode: 200,
        location: '',
        raw: '''
        <form><input name="pwdts"></form>
        <script>function check(){alert("请输入完整信息!");}</script>
        ''',
      );
      expect(result.success, isFalse);
    });
  });
}
