import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/zongce_academic.dart';
import 'package:jizhicha/zongce_docx.dart';
import 'package:jizhicha/zongce_model.dart';

/// 综测计算与导出回归测试。
///
/// 重点锁住四件事：
///  1. 计分口径（基础分 + 加减分 → 按上限截断 → 加权求和）与细则一致；
///  2. 综测等级阈值是 85/75/60，**不是**体测的 90/80/60（极易混用）；
///  3. 体育课成绩按课程名（不是 courseType）识别、按学期取数；
///  4. 导出的 .docx 以官方模板为骨架，只替换文字，其余部件原样保留。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('计分口径', () {
    test('小节得分 = 基础分 + 加减分', () {
      final r = ZongceRow(
        title: '思想道德修养',
        defaultBase: 30,
        cap: 50,
        entries: [
          ZongceEntry(note: '献血', value: 5),
          ZongceEntry(note: '团培', value: 5),
        ],
      );
      expect(r.base, 30);
      expect(r.adjustment, 10);
      expect(r.score, 40);
      expect(r.isCapped, isFalse);
    });

    test('超过满分时按满分截断，且标记 isCapped', () {
      final r = ZongceRow(
        title: '思想道德修养',
        defaultBase: 30,
        cap: 50,
        entries: [ZongceEntry(value: 30)], // 30+30=60 > 50
      );
      expect(r.rawScore, 60);
      expect(r.score, 50, reason: '必须截断到满分');
      expect(r.isCapped, isTrue);
    });

    test('减分扣到负数时按 0 计，且标记 isFloored', () {
      final r = ZongceRow(
        title: '遵章守纪',
        defaultBase: 50,
        cap: 50,
        entries: [ZongceEntry(note: '通报批评', value: -60)],
      );
      expect(r.rawScore, -10);
      expect(r.score, 0, reason: '不能出现负分');
      expect(r.isFloored, isTrue);
    });

    test('减分项在运动能力基础分上扣减', () {
      final r = ZongceRow(
        title: '运动能力',
        defaultBase: 20,
        cap: 40,
        entries: [ZongceEntry(note: '体测不及格', value: -5)],
      );
      expect(r.score, 15, reason: '20 - 5 = 15');
    });
  });

  group('默认表单结构（严格对应官方模板 12 行）', () {
    final form = buildDefaultForm();

    test('五育权重合计 100%', () {
      final sum = form.categories.fold(0.0, (a, c) => a + c.weight);
      expect(sum, closeTo(1.0, 1e-9));
    });

    test('权重分别为 德育20/智育50/体育10/美育10/劳育10', () {
      expect(form.category('德育素质')!.weight, 0.20);
      expect(form.category('智育素质')!.weight, 0.50);
      expect(form.category('体育素质')!.weight, 0.10);
      expect(form.category('美育素质')!.weight, 0.10);
      expect(form.category('劳育素质')!.weight, 0.10);
    });

    test('共 12 行，且行名与官方模板逐行一致', () {
      final titles = form.categories
          .expand((c) => c.rows)
          .map((r) => r.title)
          .toList();
      expect(titles, [
        '思想道德修养',
        '遵章守纪',
        '学业成绩',
        '学习能力',
        '体育成绩',
        '运动能力',
        '减分项', // 体育的独立减分行
        '美育课程',
        '美育素养',
        '劳动课程',
        '日常劳动',
        '减分项', // 劳育的独立减分行
      ]);
    });

    test('空白表单初始得分：德育80 智育4 体育20 美育80 劳育80', () {
      expect(form.category('德育素质')!.score, 80);
      expect(form.category('智育素质')!.score, 4);
      expect(form.category('体育素质')!.score, 20);
      expect(form.category('美育素质')!.score, 80);
      expect(form.category('劳育素质')!.score, 80);
    });

    test('总分 = 各育加权之和（空白表单为 36）', () {
      final expect0 = 80 * 0.2 + 4 * 0.5 + 20 * 0.1 + 80 * 0.1 + 80 * 0.1;
      expect(expect0, closeTo(36, 1e-9));
      expect(form.total, closeTo(expect0, 1e-9));
    });
  });

  group('等级阈值（综测 85/75/60，勿与体测 90/80/60 混用）', () {
    test('边界值', () {
      expect(zongceLevel(100), '优秀');
      expect(zongceLevel(85), '优秀');
      expect(zongceLevel(84.99), '良好');
      expect(zongceLevel(75), '良好');
      expect(zongceLevel(74.99), '合格');
      expect(zongceLevel(60), '合格');
      expect(zongceLevel(59.99), '不合格');
    });

    test('88 分在综测里是优秀（体测阈值 90 会判成良好）', () {
      expect(zongceLevel(88), '优秀');
      expect(88 >= 90, isFalse, reason: '若误用体测阈值就会算错，这条是守卫');
    });
  });

  group('智育自动计算', () {
    List<Map<String, String>> grades() => [
      {
        'course': '高等数学',
        'courseType': '专业教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '90',
      },
      {
        'course': '大学物理',
        'courseType': '专业教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '80',
      },
      {
        'course': '体育1',
        'courseType': '通识教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '95',
      },
      {
        'course': '音乐鉴赏',
        'courseType': '公共选修课',
        'term': '2025-2026-1',
        'grade': '100',
      },
    ];

    test('排除体育课与公共选修课', () {
      final r = buildAcademicAuto(grades());
      expect(r.countedCount, 2);
      expect(r.average, closeTo(85, 1e-9));
      expect(r.academicScore, closeTo(76.5, 1e-9));
    });

    test('「通识教育课程（必修）」绝不能因为含「通识」被排除', () {
      final r = buildAcademicAuto([
        {
          'course': '大学英语',
          'courseType': '通识教育课程（必修）',
          'term': 't',
          'grade': '88',
        },
        {
          'course': '体育2',
          'courseType': '通识教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
      ]);
      expect(r.countedCount, 1);
      expect(r.average, closeTo(88, 1e-9), reason: '只排除体育课');
    });

    test('文字成绩被标为无法参与平均', () {
      final r = buildAcademicAuto([
        {
          'course': '教育实习',
          'courseType': '实践教育课程（必修）',
          'term': 't',
          'grade': '良',
        },
        {
          'course': '高等数学',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
      ]);
      final nonNumeric = r.courses.where((c) => !c.hasNumericScore).toList();
      expect(nonNumeric.length, 1);
      expect(nonNumeric.first.excludedReason, contains('文字成绩'));
      expect(r.average, closeTo(90, 1e-9));
    });

    test('按学期筛选只统计该学期', () {
      final r = buildAcademicAuto([
        {
          'course': 'A',
          'courseType': '专业教育课程（必修）',
          'term': '2025-2026-1',
          'grade': '90',
        },
        {
          'course': 'B',
          'courseType': '专业教育课程（必修）',
          'term': '2025-2026-2',
          'grade': '60',
        },
      ], term: '2025-2026-1');
      expect(r.countedCount, 1);
      expect(r.average, closeTo(90, 1e-9));
    });

    test('空成绩返回 null 而不是 0 或抛错', () {
      final r = buildAcademicAuto([]);
      expect(r.average, isNull);
      expect(r.academicScore, isNull);
    });
  });

  group('体育课成绩按学期取数（按课程名识别）', () {
    final g = [
      {
        'course': '大学体育（三）',
        'courseType': '通识教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '73',
      },
      // 同一门课重复出现（实测每学期重复 3 条），取最高分
      {
        'course': '大学体育（三）',
        'courseType': '通识教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '75',
      },
      {
        'course': '大学体育（四）',
        'courseType': '通识教育课程（必修）',
        'term': '2025-2026-2',
        'grade': '81',
      },
      {
        'course': '大学英语',
        'courseType': '通识教育课程（必修）',
        'term': '2025-2026-1',
        'grade': '88',
      },
    ];

    test('取指定学期的体育课成绩', () {
      expect(peCourseScoreOf(g, term: '2025-2026-1'), 75);
      expect(peCourseScoreOf(g, term: '2025-2026-2'), 81);
    });

    test('该学期没有体育课时返回 null（如大三以后）', () {
      expect(peCourseScoreOf(g, term: '2026-2027-1'), isNull);
    });

    test('不会把非体育的通识必修课当体育课', () {
      expect(peCourseScoreOf(g, term: '2025-2026-1'), isNot(88));
    });

    test('allPeCourses 列出所有体育课且按学期倒序', () {
      final all = allPeCourses(g);
      expect(all.length, 2, reason: '同一门课去重');
      expect(all.first.term, '2025-2026-2');
    });
  });

  group('体育成绩公式（细则口径）', () {
    test('大一大二 =（体育课×50% + 体测×50%）×60%', () {
      final f = buildDefaultForm();
      f.fitnessScore = 80;
      final v = f.computeSportsScore(isSenior: false, peCourseScore: 82);
      expect(v, closeTo(48.6, 1e-9), reason: '(82×0.5 + 80×0.5)×0.6');
    });

    test('大三大四 = 体测 × 60%', () {
      final f = buildDefaultForm();
      f.fitnessScore = 85;
      expect(f.computeSportsScore(isSenior: true), closeTo(51, 1e-9));
    });

    test('参数不足返回 null 而不是算成 0', () {
      final f = buildDefaultForm();
      expect(f.computeSportsScore(isSenior: true), isNull, reason: '没填体测');
      f.fitnessScore = 80;
      expect(
        f.computeSportsScore(isSenior: false, peCourseScore: null),
        isNull,
        reason: '大一大二还需要体育课成绩',
      );
    });

    test('免测/免修常量与细则一致', () {
      expect(kFitnessExemptScore, 60);
      expect(kSportsExemptScore, 48, reason: '80 × 60% = 48');
    });

    test('旧版独立换算函数仍可用', () {
      expect(
        computeSportsScore(isSenior: false, peCourseScore: 90, fitnessScore: 80),
        closeTo(51, 1e-9),
      );
    });
  });

  group('体测成绩表（xlsx）导入', () {
    /// 造一个最小 xlsx：表头在第 1 行（第 0 行是标题），考识别能力。
    Uint8List makeXlsx(List<List<String>> grid) {
      final shared = <String>[];
      int sid(String s) {
        final i = shared.indexOf(s);
        if (i >= 0) return i;
        shared.add(s);
        return shared.length - 1;
      }

      final rowsXml = StringBuffer();
      for (var r = 0; r < grid.length; r++) {
        rowsXml.write('<row r="${r + 1}">');
        for (var c = 0; c < grid[r].length; c++) {
          final v = grid[r][c];
          if (v.isEmpty) continue;
          final ref = '${String.fromCharCode(65 + c)}${r + 1}';
          rowsXml.write('<c r="$ref" t="s"><v>${sid(v)}</v></c>');
        }
        rowsXml.write('</row>');
      }

      final sheet =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData>$rowsXml</sheetData></worksheet>';

      final ssXml =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="${shared.length}" uniqueCount="${shared.length}">'
          '${shared.map((s) => '<si><t>${s.replaceAll('&', '&amp;').replaceAll('<', '&lt;')}</t></si>').join()}'
          '</sst>';

      final wb =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';

      final rels =
          '<?xml version="1.0" encoding="UTF-8"?>'
          '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
          '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
          '</Relationships>';

      final ar = Archive();
      void add(String name, String content) {
        final b = utf8.encode(content);
        ar.addFile(ArchiveFile(name, b.length, b));
      }

      add('xl/workbook.xml', wb);
      add('xl/_rels/workbook.xml.rels', rels);
      add('xl/worksheets/sheet1.xml', sheet);
      add('xl/sharedStrings.xml', ssXml);
      return Uint8List.fromList(ZipEncoder().encode(ar));
    }

    final grid = [
      ['2025学年体测成绩表', '', '', ''],
      ['学号', '姓名', '班级', '总分'],
      ['202400000000', '张三', '生教2401', '82.5'],
      ['202400000001', '李四', '生教2401', '77'],
    ];

    test('能读到二维表', () {
      final g = parseXlsxGrid(makeXlsx(grid));
      expect(g.length, 4);
      expect(g[1][0], '学号');
      expect(g[2][0], '202400000000');
      expect(g[2][3], '82.5');
    });

    test('自动跳过标题行找到表头，并识别三列', () {
      final cols = detectColumns(parseXlsxGrid(makeXlsx(grid)));
      expect(cols, isNotNull);
      expect(cols!.headerRow, 1, reason: '第 0 行是标题，表头在第 1 行');
      expect(cols.idCol, 0);
      expect(cols.nameCol, 1);
      expect(cols.totalCol, 3);
      expect(cols.hasIdentity, isTrue);
      expect(cols.hasTotal, isTrue);
    });

    test('按学号 + 姓名强筛选，取出总分', () {
      final cols = detectColumns(parseXlsxGrid(makeXlsx(grid)))!;
      final m = matchStudent(cols, '202400000000', '张三');
      expect(m.length, 1);
      expect(m.first.total, closeTo(82.5, 1e-9));
      expect(m.first.rawTotal, '82.5');
    });

    test('学号对但姓名不对 → 不匹配（防重名误取）', () {
      final cols = detectColumns(parseXlsxGrid(makeXlsx(grid)))!;
      expect(matchStudent(cols, '202400000000', '李四'), isEmpty);
      expect(matchStudent(cols, '999999999999', '张三'), isEmpty);
    });

    test('学号或姓名为空时不匹配任何人', () {
      final cols = detectColumns(parseXlsxGrid(makeXlsx(grid)))!;
      expect(matchStudent(cols, '', '张三'), isEmpty);
      expect(matchStudent(cols, '202400000000', ''), isEmpty);
    });

    test('匹配时忽略空白差异', () {
      final g2 = [
        ['学号', '姓名', '总分'],
        [' 202400000000 ', ' 张 三 ', ' 82.5 '],
      ];
      final cols = detectColumns(parseXlsxGrid(makeXlsx(g2)))!;
      final m = matchStudent(cols, '202400000000', '张三');
      expect(m.length, 1);
      expect(m.first.total, closeTo(82.5, 1e-9));
    });

    test('没有学号/姓名列时返回 null（让界面提示用户）', () {
      final g3 = [
        ['项目', '成绩'],
        ['身高', '175'],
      ];
      expect(detectColumns(parseXlsxGrid(makeXlsx(g3))), isNull);
    });
  });

  group('年级自动推断（不让用户手选，避免选错导致公式用错）', () {
    test('学号 2024 入学 + 2024-2025-1 → 大一（非高年级）', () {
      expect(
        inferIsSenior(studentId: '202400000000', term: '2024-2025-1'),
        isFalse,
      );
    });

    test('学号 2024 入学 + 2025-2026-1 → 大二（仍非高年级）', () {
      expect(
        inferIsSenior(studentId: '202400000000', term: '2025-2026-1'),
        isFalse,
      );
    });

    test('学号 2024 入学 + 2026-2027-1 → 大三（高年级）', () {
      expect(
        inferIsSenior(studentId: '202400000000', term: '2026-2027-1'),
        isTrue,
      );
    });

    test('学号 2024 入学 + 2027-2028-1 → 大四（高年级）', () {
      expect(
        inferIsSenior(studentId: '202400000000', term: '2027-2028-1'),
        isTrue,
      );
    });

    test('信息不足或明显不合理时返回 null（由调用方按大一大二兜底）', () {
      expect(inferIsSenior(studentId: '', term: '2025-2026-1'), isNull);
      expect(inferIsSenior(studentId: '202400000000', term: ''), isNull);
      expect(inferIsSenior(studentId: 'abc', term: 'xyz'), isNull);
      // 学期年份早于入学年 → 不合理，别瞎猜
      expect(
        inferIsSenior(studentId: '202400000000', term: '2020-2021-1'),
        isNull,
      );
    });
  });

  group('存档容错（早期版本写坏过 value，必须不再崩页）', () {
    test('value 为 bool 时按 0 处理，不抛类型转换异常', () {
      final e = ZongceEntry.fromJson({'note': '坏数据', 'value': true});
      expect(e.value, 0, reason: '曾抛 type bool is not a subtype of double?');
      expect(e.note, '坏数据');
    });

    test('value 为字符串数字时能解析', () {
      expect(ZongceEntry.fromJson({'value': '5.5'}).value, closeTo(5.5, 1e-9));
    });

    test('value 为无法解析的字符串时按 0', () {
      expect(ZongceEntry.fromJson({'value': 'abc'}).value, 0);
    });

    test('base / fitnessScore 为 bool 时回落默认值，不崩页', () {
      final f = buildDefaultForm();
      f.restore({
        'fitnessScore': true,
        'categories': {
          '德育素质': {
            '思想道德修养': {'base': false, 'entries': []},
          },
        },
      });
      expect(f.fitnessScore, isNull);
      expect(f.moral!.base, 30, reason: '坏值应回落到默认基础分');
    });

    test('toDoubleLoose 覆盖各种输入', () {
      expect(ZongceEntry.toDoubleLoose(3), 3.0);
      expect(ZongceEntry.toDoubleLoose(3.5), 3.5);
      expect(ZongceEntry.toDoubleLoose('4.25'), 4.25);
      expect(ZongceEntry.toDoubleLoose(''), isNull);
      expect(ZongceEntry.toDoubleLoose(true), isNull);
      expect(ZongceEntry.toDoubleLoose([1, 2]), isNull);
      expect(ZongceEntry.toDoubleLoose(null), isNull);
    });
  });

  group('存档往返', () {
    test('保存再恢复后数值保留', () {
      final form = buildDefaultForm(term: '2025-2026-1');
      form.className = '生教2401班';
      form.fitnessScore = 80;
      form.moral!.entries.add(ZongceEntry(note: '献血', value: 5));
      form.academic!.base = 81.5;
      final before = form.total;

      final json = jsonDecode(jsonEncode(form.toJson()));
      final restored = buildDefaultForm();
      restored.restore((json as Map).cast<String, dynamic>());

      expect(restored.className, '生教2401班');
      expect(restored.term, '2025-2026-1');
      expect(restored.fitnessScore, 80);
      expect(restored.moral!.entries.first.note, '献血');
      expect(restored.academic!.base, closeTo(81.5, 1e-9));
      expect(restored.total, closeTo(before, 1e-9));
    });

    test('不存在的图片路径在读档时被剔除', () {
      final form = buildDefaultForm();
      form.restore({
        'categories': {
          '德育素质': {
            '思想道德修养': {
              'base': 30,
              'entries': [
                {
                  'note': '献血',
                  'value': 5,
                  'images': ['/definitely/not/here.png'],
                },
              ],
            },
          },
        },
      });
      expect(form.moral!.entries.length, 1);
      expect(
        form.moral!.entries.first.images,
        isEmpty,
        reason: '文件不在就清掉，避免导出时静默丢图',
      );
    });

    test('存档缺字段时回落到默认值，不抛错', () {
      final form = buildDefaultForm();
      form.restore({'college': '化生院'});
      expect(form.college, '化生院');
      expect(form.moral!.base, 30);
    });

    test('clearAll 只清数值，保留预定义结构', () {
      final form = buildDefaultForm();
      form.moral!.entries.add(ZongceEntry(value: 5));
      form.fitnessScore = 90;
      form.clearAll();
      expect(form.moral!.entries, isEmpty);
      expect(form.moral!.base, 30);
      expect(form.fitnessScore, isNull);
      expect(form.categories.length, 5);
    });
  });

  group('导出 Word（以官方模板为骨架）', () {
    late Uint8List tpl;

    setUpAll(() {
      tpl = File('assets/templates/zongce_form_template.docx').readAsBytesSync();
    });

    ZongceForm filled() {
      final f = buildDefaultForm(term: '2025-2026-1');
      f.className = '生教2401班';
      f.studentId = '2024xxxxxx';
      f.name = '测试';
      f.fitnessScore = 80;
      f.moral!.entries.add(ZongceEntry(note: '团培', value: 5));
      f.moral!.entries.add(ZongceEntry(note: '献血', value: 5));
      f.academic!.base = 81.5;
      f.learning!.entries.add(ZongceEntry(note: '英语四级', value: 2));
      f.sportsScore!.base = 48.6;
      return f;
    }

    Map<String, List<int>> unzip(Uint8List bytes) {
      final a = ZipDecoder().decodeBytes(bytes);
      return {
        for (final f in a.files)
          if (f.isFile) f.name: List<int>.from(f.content as List<int>),
      };
    }

    test('保留模板的全部部件（不被精简掉）', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final parts = unzip(r.bytes);
      for (final name in [
        '[Content_Types].xml',
        '_rels/.rels',
        'word/document.xml',
        'word/_rels/document.xml.rels',
        'word/styles.xml',
        'word/settings.xml',
        'word/fontTable.xml',
        'word/theme/theme1.xml',
        'docProps/core.xml',
        'docProps/app.xml',
        'docProps/custom.xml',
      ]) {
        expect(parts.keys, contains(name), reason: '模板部件 $name 必须保留');
      }
    });

    test('页边距等节属性原样保留（证明没用自建页面设置）', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(doc, contains('w:top="1440"'));
      expect(doc, contains('w:left="1800"'));
    });

    test('列宽沿用官方模板（720/2520/5400/540）', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(doc, contains('w:w="5400"'), reason: '参与情况列的宽度');
      expect(doc, contains('w:w="2520"'), reason: '项目列的宽度');
    });

    test('填入了分数与参与情况文字', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(doc, contains('基础分 30 分'));
      expect(doc, contains('团培'));
      expect(doc, contains('献血'));
      expect(doc, contains('81.5'), reason: '学业成绩');
      expect(doc, contains('生教2401班'));
      expect(doc, contains('2024xxxxxx'));
    });

    test('表头与项目名等模板原文保持不变（框架不动）', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      for (final anchor in [
        '考核内容',
        '个人在该项中的参与情况',
        '思想道德修养',
        '遵章守纪',
        '学业成绩',
        '学习能力',
        '体育成绩',
        '运动能力',
        '美育课程',
        '美育素养',
        '劳动课程',
        '日常劳动',
        '最终得分',
      ]) {
        expect(doc, contains(anchor), reason: '模板文字「$anchor」不应被改动');
      }
    });

    test('表格仍是 14 行（结构没被破坏）', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(RegExp(r'<w:tr>').allMatches(doc).length, 14);
    });

    test('汇总行填了各育加权分', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(doc, contains('德育20%'));
      expect(doc, contains('智育50%'));
      expect(doc, contains('体育10%'));
    });

    test('没有图片时不产生 media 部件', () async {
      final r = await buildZongceDocx(filled(), templateBytes: tpl);
      final parts = unzip(r.bytes);
      expect(r.imageCount, 0);
      expect(parts.keys.where((k) => k.startsWith('word/media/')), isEmpty);
    });

    test('带图片时：media 落盘、关系登记、Content_Types 声明 png、补命名空间', () async {
      // 最小合法 PNG 文件头：宽 64 高 32
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x40,
        0x00,
        0x00,
        0x00,
        0x20,
        0x08,
        0x06,
        0x00,
        0x00,
        0x00,
      ]);
      final f = filled();
      f.moral!.entries.first.images.add('proof.png');

      final r = await buildZongceDocx(
        f,
        templateBytes: tpl,
        readImage: (p) async => png,
      );
      final parts = unzip(r.bytes);

      expect(r.imageCount, 1);
      expect(parts.keys, contains('word/media/image1.png'));

      final doc = utf8.decode(parts['word/document.xml']!);
      expect(doc, contains('<w:drawing>'));
      expect(doc, contains('r:embed="rId'));
      // 模板原本没有 DrawingML 命名空间，必须补上，否则 Word 打不开
      expect(
        doc,
        contains('xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'),
      );
      expect(doc, contains('xmlns:pic="'));

      final rels = utf8.decode(parts['word/_rels/document.xml.rels']!);
      expect(rels, contains('media/image1.png'));
      expect(rels, contains('/image'));
      // 模板原有的关系不能被冲掉
      expect(rels, contains('styles.xml'));
      expect(rels, contains('theme/theme1.xml'));

      expect(utf8.decode(parts['[Content_Types].xml']!), contains('Extension="png"'));
    });

    test('读不到的图片被跳过，不阻断导出', () async {
      final f = filled();
      f.moral!.entries.first.images.add('missing.png');
      final r = await buildZongceDocx(
        f,
        templateBytes: tpl,
        readImage: (p) async => null,
      );
      expect(r.imageCount, 0);
      expect(r.bytes.length, greaterThan(500));
    });

    test('图片等比缩放到单元格内（不超出上限）', () {
      final (w1, h1) = displaySizeFor(4000, 1000);
      expect(w1, 1645920);
      expect(h1, lessThan(2194560));

      final (w2, h2) = displaySizeFor(500, 4000);
      expect(h2, 2194560);
      expect(w2, lessThan(1645920));

      // 尺寸未知时给稳妥默认值，不能是 0（0 会让 Word 不显示图片）
      final (w3, h3) = displaySizeFor(0, 0);
      expect(w3, greaterThan(0));
      expect(h3, greaterThan(0));
    });

    test('PNG 文件头能解析出宽高', () {
      final png = Uint8List.fromList([
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
        0x49,
        0x48,
        0x44,
        0x52,
        0x00,
        0x00,
        0x00,
        0x40,
        0x00,
        0x00,
        0x00,
        0x20,
      ]);
      expect(decodeImageSize(png), (64, 32));
    });

    test('非图片数据返回 (0,0)（用于拦截误选的文件）', () {
      expect(decodeImageSize(Uint8List.fromList([1, 2, 3, 4, 5])), (0, 0));
      expect(decodeImageSize(Uint8List(0)), (0, 0));
    });

    test('参与情况自动生成描述文字', () {
      final r = ZongceRow(
        title: '思想道德修养',
        defaultBase: 30,
        cap: 50,
        entries: [
          ZongceEntry(note: '团培', value: 5),
          ZongceEntry(note: '献血', value: 5),
        ],
      );
      final desc = describeEntries(r);
      expect(desc, contains('团培'));
      expect(desc, contains('献血'));
      expect(desc, contains('+5'));
    });

    test('空记录不产生多余描述', () {
      final r = ZongceRow(title: 'x', defaultBase: 0);
      expect(describeEntries(r), isEmpty);
      r.entries.add(ZongceEntry());
      expect(describeEntries(r), isEmpty);
    });

    test('分数格式化：整数不带小数点', () {
      expect(fmtNum(30), '30');
      expect(fmtNum(30.0), '30');
      expect(fmtNum(76.55), '76.55');
      expect(fmtNum(48.6), '48.6');
    });

    test('XML 特殊字符被转义', () async {
      final f = filled();
      f.name = 'A&B<C>';
      f.moral!.entries.first.note = '科研&竞赛';
      final r = await buildZongceDocx(f, templateBytes: tpl);
      final doc = utf8.decode(unzip(r.bytes)['word/document.xml']!);
      expect(doc, contains('A&amp;B&lt;C&gt;'));
      expect(doc, contains('科研&amp;竞赛'));
      expect(RegExp(r'&(?!amp;|lt;|gt;|quot;|apos;|#)').hasMatch(doc), isFalse);
    });
  });
}
