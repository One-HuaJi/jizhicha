import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/zongce_academic.dart';
import 'package:jizhicha/zongce_docx.dart';
import 'package:jizhicha/zongce_model.dart';

/// 本轮四项改动的回归测试。
///
/// 背景（用户反馈）：
///  1. 体育/劳育的「减分项」基础分**无法为负** —— 细则说「在运动能力基础分
///     20 分上扣减」，所以它应当允许负数且**并入**目标行，而不是自成一个
///     百分制小节。
///  2. 大三没有体育课，用的是大二下的体测成绩，需要能直接输入体育成绩。
///  3. 学业成绩导出要写成「共 x 科，（a+b+c…）/x = 平均分」。
///  4. 导出表里总分右边不要「（合格）」这个等级标记。
void main() {
  group('减分项语义（并入目标行、允许为负）', () {
    test('减分项自身得分允许为负', () {
      final f = buildDefaultForm();
      final d = f.sportsDeduct!;
      d.entries.add(ZongceEntry(note: '体测不及格', value: -5));
      expect(d.isDeduction, isTrue);
      expect(d.score, -5, reason: '减分项不能被钳到 0');
      expect(d.isFloored, isFalse, reason: '减分项不适用下限');
    });

    test('非减分项仍不允许为负', () {
      final f = buildDefaultForm();
      final r = f.moral!;
      r.entries.add(ZongceEntry(note: '扣分', value: -999));
      expect(r.score, 0);
      expect(r.isFloored, isTrue);
    });

    test('减分并入运动能力：20 - 5 = 15', () {
      final f = buildDefaultForm();
      f.sportsDeduct!.entries.add(ZongceEntry(note: '体测不及格', value: -5));
      expect(f.sportsAbility!.score, 20, reason: '运动能力自身仍是 20');
      // 体育 = 体育成绩0 + 运动能力(20-5) = 15
      expect(f.category('体育素质')!.score, 15);
    });

    test('减分不单独占一个百分制小节（否则总分虚高）', () {
      final f = buildDefaultForm();
      f.sportsDeduct!.entries.add(ZongceEntry(value: -5));
      final sports = f.category('体育素质')!;
      // 若错误地把减分项当成独立小节相加，会得到 0 + 20 + (-5) = 15 也一样，
      // 所以用「没有减分项时」对照：两者应相差恰好 5 分。
      final f2 = buildDefaultForm();
      expect(
        sports.score,
        f2.category('体育素质')!.score - 5,
        reason: '减 5 分就应恰好少 5 分',
      );
    });

    test('劳育减分并入日常劳动', () {
      final f = buildDefaultForm();
      expect(f.laborDeduct!.foldedInto, '日常劳动');
      f.laborDeduct!.entries.add(ZongceEntry(value: -4));
      // 劳育 = 劳动课程60 + 日常劳动(20-4) = 76
      expect(f.category('劳育素质')!.score, 76);
    });

    test('扣到负数时该育整体按 0 计（不出现负的育总分）', () {
      final f = buildDefaultForm();
      f.sportsAbility!.base = 0;
      f.sportsDeduct!.entries.add(ZongceEntry(value: -50));
      expect(f.category('体育素质')!.score, 0);
    });

    test('并入后仍受目标行满分限制', () {
      // 满上限时扣分仍应生效：40 - 5 = 35（不能因为"已满"就无视扣分）
      final f = buildDefaultForm();
      f.sportsAbility!.base = 40;
      f.sportsDeduct!.entries.add(ZongceEntry(value: -5));
      expect(f.category('体育素质')!.score, 35);

      // 反向：并入的是**加分**且超过满分时，应被 cap 住
      final f2 = buildDefaultForm();
      f2.sportsAbility!.base = 40;
      f2.sportsDeduct!.entries.add(ZongceEntry(value: 100));
      expect(f2.category('体育素质')!.score, 40, reason: '并入后不得超满分');
    });
  });

  group('学业成绩算式文案', () {
    // 注意：buildAcademicAuto 会按课程名排序，所以算式里的顺序是**排序后**的，
    // 不是录入顺序。测试用拼音序靠前的名字以免踩这个坑。

    test('第一行是「共 x 科，（a+b+…）/x = 平均分」', () {
      final r = buildAcademicAuto([
        {
          'course': 'A科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
        {
          'course': 'B科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '80',
        },
        {
          'course': 'C科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '85',
        },
      ]);
      final lines = r.describeCalculation(fmtNum).split('\n');
      expect(lines.first, '共 3 科，（90+80+85）/3 = 85');
    });

    test('第二行逐科列出科目名与分数（老师要核对算了哪些课）', () {
      final r = buildAcademicAuto([
        {
          'course': 'A科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
        {
          'course': 'B科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '80',
        },
      ]);
      final lines = r.describeCalculation(fmtNum).split('\n');
      expect(lines.length, 2, reason: '算式一行 + 明细一行');
      expect(lines[1], 'A科 90、B科 80');
    });

    test('明细行与算式行的科目**一一对应**（顺序必须一致）', () {
      final r = buildAcademicAuto([
        {
          'course': 'A科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
        {
          'course': 'B科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '80',
        },
        {
          'course': 'C科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '85',
        },
      ]);
      final lines = r.describeCalculation(fmtNum).split('\n');
      // 算式里的分数顺序 == 明细里的分数顺序
      final scoresInFormula =
          RegExp(r'（([\d+]+)）/').firstMatch(lines[0])!.group(1)!.split('+');
      final scoresInDetail =
          lines[1].split('、').map((e) => e.split(' ').last).toList();
      expect(scoresInDetail, scoresInFormula, reason: '两行顺序必须一致，否则老师对不上');
    });

    test('单科也能正确生成两行', () {
      final r = buildAcademicAuto([
        {
          'course': '生态学',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '88',
        },
      ]);
      final lines = r.describeCalculation(fmtNum).split('\n');
      expect(lines[0], '共 1 科，（88）/1 = 88');
      expect(lines[1], '生态学 88');
    });

    test('无有效课程时返回空串（不生成残缺文案）', () {
      final r = buildAcademicAuto([]);
      expect(r.describeCalculation(fmtNum), isEmpty);
    });

    test('文字成绩不进入算式（避免"良"参与加法，也不列进明细）', () {
      final r = buildAcademicAuto([
        {
          'course': 'A科',
          'courseType': '专业教育课程（必修）',
          'term': 't',
          'grade': '90',
        },
        {
          'course': '实习',
          'courseType': '实践教育课程（必修）',
          'term': 't',
          'grade': '良',
        },
      ]);
      final desc = r.describeCalculation(fmtNum);
      expect(desc, contains('共 1 科'));
      expect(desc, isNot(contains('良')));
      expect(desc, isNot(contains('实习')));
    });
  });

  group('导出：学业成绩算式与去掉等级标记', () {
    test('detail 会出现在参与情况列', () {
      final f = buildDefaultForm();
      f.academic!.base = 76.5;
      f.academic!.detail = '共 12 科，（87+92+85）/3 = 88';
      final lines = participationLines(f.academic!);
      expect(lines.first, '基础分 76.5 分', reason: '基础分在前');
      expect(lines[1], contains('共 12 科'), reason: '算式紧随其后');
    });

    test('手动改分会清掉 detail（由界面负责，这里验证语义）', () {
      final row = ZongceRow(title: '学业成绩', defaultBase: 0);
      row.detail = '共 3 科，（90+80+85）/3 = 85';
      expect(participationLines(row).last, contains('共 3 科'));
      row.base = 70;
      row.detail = '';
      expect(participationLines(row), ['基础分 70 分']);
    });

    test('减分项文案说明扣了多少、计入哪一行', () {
      final f = buildDefaultForm();
      final d = f.sportsDeduct!;
      d.entries.add(ZongceEntry(note: '体测不及格', value: -5));
      final lines = deductionLines(d, d.foldedInto!);
      expect(lines.join('\n'), contains('体测不及格'));
      expect(lines.join('\n'), contains('-5'));
      expect(lines.join('\n'), contains('运动能力'));
      // 不应出现「基础分 0 分」这种让人困惑的写法
      expect(lines.join('\n'), isNot(contains('基础分 0 分')));
    });

    test('无扣分时减分项写「无」', () {
      final f = buildDefaultForm();
      final lines = deductionLines(f.sportsDeduct!, '运动能力');
      expect(lines, ['无']);
    });

    test('detail 会随存档往返保存', () {
      final f = buildDefaultForm();
      f.academic!.detail = '共 3 科，（90+80+85）/3 = 85';
      final j = f.toJson();
      final f2 = buildDefaultForm();
      f2.restore(j);
      expect(f2.academic!.detail, '共 3 科，（90+80+85）/3 = 85');
    });
  });
}
