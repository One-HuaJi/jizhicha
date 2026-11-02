import 'package:flutter_test/flutter_test.dart';
import 'package:jizhicha/grades_page.dart';

// 成绩页统计口径单测（历史欠账：成绩页原本 0 个测试）。
//
// 覆盖两条作者已确认的口径：
//   1) GPA = 全部课程 · Σ(学分×绩点)/Σ学分，重修取最高分那条记录，
//      公共选修计入，绩点缺失容错，无数据回退「—」。
//   2) 专业课挂科门数 = 课程性质「括号内含必修」的课程里挂过科的课，
//      按课程身份（课程名+编码）去重，一门最多算 1 门；非专业课不计入。
//
// 全部数据为占位（示例课程 / 202400000000 / 生教2401班），不含任何真实信息。

/// 构造一条统计快照；[isFail] 默认按成绩现算，需要模拟「归档合并后
/// 任一次未通过」的语义时显式传 true。
GradeStatRecord _rec({
  String course = '示例课程',
  String code = '202400000000',
  String credit = '3',
  String courseType = '学科基础课（必修）',
  String grade = '85',
  String gpa = '3.5',
  String term = '2024-2025-1',
  bool? isFail,
}) => GradeStatRecord(
  course: course,
  code: code,
  credit: credit,
  courseType: courseType,
  grade: grade,
  gpa: gpa,
  isFail: isFail ?? isGradeFail(grade),
  term: term,
);

void main() {
  group('computeWeightedGpa：Σ(学分×绩点)/Σ学分', () {
    test('三门课按学分加权', () {
      final gpa = computeWeightedGpa([
        _rec(code: '202400000001', credit: '3', grade: '80', gpa: '3.0'),
        _rec(code: '202400000002', credit: '2', grade: '95', gpa: '4.0'),
        _rec(code: '202400000003', credit: '4', grade: '75', gpa: '2.5'),
      ]);
      // (3×3.0 + 2×4.0 + 4×2.5) / (3+2+4) = 27 / 9 = 3.00
      expect(gpa, isNotNull);
      expect(gpa!, closeTo(3.0, 1e-9));
    });

    test('重修取最高分那条记录（跨学期同一门课不重复计入学分）', () {
      final records = [
        // 第一次：55 分 / 绩点 0
        _rec(
          credit: '3',
          grade: '55',
          gpa: '0',
          term: '2024-2025-1',
          isFail: true,
        ),
        // 重修：72 分 / 绩点 2.0，同一门课（课程名 + 编码相同）
        _rec(credit: '3', grade: '72', gpa: '2.0', term: '2024-2025-2'),
        _rec(
          course: '示例课程二',
          code: '202400000012',
          credit: '2',
          grade: '90',
          gpa: '3.0',
        ),
      ];

      final collapsed = collapseByCourseIdentity(records);
      expect(collapsed, hasLength(2), reason: '同一门课的两条记录必须折叠成一条');
      final retaken = collapsed.firstWhere((r) => r.code == '202400000000');
      expect(retaken.grade, '72');
      expect(retaken.gpa, '2.0', reason: '绩点必须跟着代表成绩（最高分）走');
      expect(retaken.isFail, isTrue, reason: '任一次未通过 → 仍是历史补考/重修');

      final gpa = computeWeightedGpa(records);
      // (3×2.0 + 2×3.0) / (3+2) = 12 / 5 = 2.40
      // 若不折叠会是 (3×0 + 3×2.0 + 2×3.0) / 8 = 1.50（学分被重复计入）
      expect(gpa!, closeTo(2.4, 1e-9));
    });

    test('公共选修计入 GPA', () {
      final gpa = computeWeightedGpa([
        _rec(
          code: '202400000021',
          credit: '2',
          courseType: '公共选修',
          grade: '90',
          gpa: '4.0',
        ),
        _rec(code: '202400000022', credit: '2', grade: '80', gpa: '3.0'),
      ]);
      // (2×4.0 + 2×3.0) / 4 = 3.50
      expect(gpa!, closeTo(3.5, 1e-9));
    });

    test('挂科课程也计入 GPA（口径为全部课程，不筛选）', () {
      final gpa = computeWeightedGpa([
        _rec(code: '202400000031', credit: '3', grade: '50', gpa: '0'),
        _rec(code: '202400000032', credit: '1', grade: '90', gpa: '4.0'),
      ]);
      // (3×0 + 1×4.0) / 4 = 1.00
      expect(gpa!, closeTo(1.0, 1e-9));
    });

    test('绩点缺失/非数字 → 整条跳过，学分不进分母', () {
      final missing = computeWeightedGpa([
        _rec(code: '202400000041', credit: '3', grade: '85', gpa: '3.0'),
        _rec(code: '202400000042', credit: '7', grade: '88', gpa: ''),
      ]);
      expect(missing!, closeTo(3.0, 1e-9), reason: '7 学分那条不计入分子也不计入分母');

      final nonNumeric = computeWeightedGpa([
        _rec(code: '202400000041', credit: '3', grade: '85', gpa: '3.0'),
        _rec(code: '202400000043', credit: '7', grade: '优秀', gpa: '优秀'),
      ]);
      expect(nonNumeric!, closeTo(3.0, 1e-9));
    });

    test('学分缺失 / 非数字 / 0 → 整条跳过', () {
      final gpa = computeWeightedGpa([
        _rec(code: '202400000051', credit: '0', grade: '90', gpa: '4.0'),
        _rec(code: '202400000052', credit: '', grade: '90', gpa: '4.0'),
        _rec(code: '202400000053', credit: 'A', grade: '90', gpa: '4.0'),
        _rec(code: '202400000054', credit: '2', grade: '90', gpa: '3.0'),
      ]);
      expect(gpa!, closeTo(3.0, 1e-9));
    });

    test('全部绩点缺失 → null，显示「—」而不是 NaN', () {
      final gpa = computeWeightedGpa([
        _rec(code: '202400000061', gpa: ''),
        _rec(code: '202400000062', gpa: '无'),
      ]);
      expect(gpa, isNull);
      expect(formatGpaText(gpa), '—');
    });

    test('空数据 → null，显示「—」', () {
      final gpa = computeWeightedGpa(const []);
      expect(gpa, isNull);
      expect(formatGpaText(gpa), '—');
    });

    test('老缓存没有 gpa 键（fromGradeMap 得到空串）→ 不计入', () {
      final record = GradeStatRecord.fromGradeMap({
        'course': '示例课程',
        'code': '202400000071',
        'credit': '3',
        'grade': '90',
        'courseType': '学科基础课（必修）',
        'term': '2024-2025-1',
      });
      expect(record.gpa, '');
      expect(computeWeightedGpa([record]), isNull);
    });
  });

  group('formatGpaText：两位小数 / 仅 2 位', () {
    test('保留两位小数', () {
      expect(formatGpaText(3.456), '3.46');
      expect(formatGpaText(3.0), '3.00');
      expect(formatGpaText(4), '4.00');
      expect(formatGpaText(null), '—');
      expect(formatGpaText(double.nan), '—');
      expect(formatGpaText(double.infinity), '—');
    });
  });

  group('isMajorCourseByCourseType：括号内含「必修」才算专业课', () {
    test('常见取值的判定表', () {
      expect(isMajorCourseByCourseType('通识必修'), isTrue, reason: '无括号 → 整串含必修');
      expect(isMajorCourseByCourseType('公共选修'), isFalse);
      expect(isMajorCourseByCourseType('学科基础课（必修）'), isTrue);
      expect(isMajorCourseByCourseType('学科基础课(必修)'), isTrue, reason: '半角括号');
      expect(isMajorCourseByCourseType('专业方向课（选修）'), isFalse);
      expect(isMajorCourseByCourseType('必修课'), isTrue);
      expect(isMajorCourseByCourseType('专业选修'), isFalse);
      expect(isMajorCourseByCourseType(''), isFalse, reason: '课程性质缺失 → 不算');
      expect(isMajorCourseByCourseType('  （必修）  '), isTrue, reason: '首尾空格不影响');
    });

    test('有括号时只看括号内（括号内没有必修就不算）', () {
      expect(
        isMajorCourseByCourseType('必修课（校级公选）'),
        isFalse,
        reason: '规则是"取括号内的文字"，括号内不含必修即不算',
      );
    });
  });

  group('countMajorCourseFails：专业课挂科门数（按课程去重）', () {
    test('同一门课多条记录（含重修不过）只算 1 门', () {
      final count = countMajorCourseFails([
        _rec(
          credit: '3',
          grade: '55',
          gpa: '0',
          term: '2024-2025-1',
          isFail: true,
        ),
        _rec(
          credit: '3',
          grade: '58',
          gpa: '0',
          term: '2024-2025-2',
          isFail: true,
        ),
        _rec(
          course: '示例课程二',
          code: '202400000012',
          grade: '45',
          gpa: '0',
          isFail: true,
        ),
      ]);
      expect(count, 2);
    });

    test('非专业课挂科不计入', () {
      expect(
        countMajorCourseFails([
          _rec(
            code: '202400000081',
            courseType: '公共选修',
            grade: '50',
            isFail: true,
          ),
        ]),
        0,
      );
      expect(
        countMajorCourseFails([
          _rec(
            code: '202400000082',
            courseType: '通识必修',
            grade: '50',
            isFail: true,
          ),
        ]),
        1,
        reason: '无括号但含必修 → 算专业课',
      );
    });

    test('同名但课程编码不同 → 是两门课，算 2 门', () {
      expect(
        countMajorCourseFails([
          _rec(code: '202400000091', grade: '50', isFail: true),
          _rec(code: '202400000092', grade: '50', isFail: true),
        ]),
        2,
      );
    });

    test('同名且编码都为空 → 回退用课程名去重，只算 1 门', () {
      expect(
        countMajorCourseFails([
          _rec(code: '', grade: '50', term: '2024-2025-1', isFail: true),
          _rec(code: '', grade: '52', term: '2024-2025-2', isFail: true),
        ]),
        1,
      );
    });

    test('同一门课不同记录性质不一致 → 任一条判必修即算专业课', () {
      expect(
        countMajorCourseFails([
          _rec(
            code: '202400000111',
            courseType: '公共选修',
            grade: '50',
            isFail: true,
          ),
          _rec(
            code: '202400000111',
            courseType: '通识必修',
            grade: '88',
            gpa: '3.8',
          ),
        ]),
        1,
      );
      expect(
        countMajorCourseFails([
          _rec(
            code: '202400000112',
            courseType: '公共选修',
            grade: '50',
            isFail: true,
          ),
          _rec(code: '202400000112', courseType: '专业方向课（选修）', grade: '88'),
        ]),
        0,
        reason: '两条性质都判不出必修 → 不是专业课',
      );
      expect(
        countMajorCourseFails([
          // 挂科那条的 courseType 为空（解析器 `cells.length > 13` 保护导致），
          // 另一条同门课记录是通识必修 → 仍算 1 门专业课挂科，不漏计
          _rec(code: '202400000113', courseType: '', grade: '50', isFail: true),
          _rec(code: '202400000113', courseType: '通识必修', grade: '88'),
        ]),
        1,
      );
    });

    test('未挂科的课程与混算场景', () {
      final count = countMajorCourseFails([
        // 专业课挂科，且重修过一次（只算 1 门）
        _rec(code: '202400000101', grade: '40', isFail: true),
        _rec(
          code: '202400000101',
          grade: '42',
          term: '2024-2025-2',
          isFail: true,
        ),
        // 专业课通过
        _rec(code: '202400000102', grade: '88', gpa: '3.8'),
        // 非专业课挂科（不计入）
        _rec(
          code: '202400000103',
          courseType: '公共选修',
          grade: '30',
          isFail: true,
        ),
        // 括号内是选修 → 不算专业课
        _rec(
          code: '202400000104',
          courseType: '专业方向课（选修）',
          grade: '30',
          isFail: true,
        ),
      ]);
      expect(count, 1);
    });
  });

  group('gradeCourseIdentity：去重键', () {
    test('课程名 + 编码；编码为空时只用课程名', () {
      expect(
        gradeCourseIdentity(_rec(course: '示例课程', code: '202400000000')),
        '示例课程|202400000000',
      );
      expect(gradeCourseIdentity(_rec(course: '示例课程', code: '')), '示例课程');
      // 学期 / 成绩 / 绩点不参与身份键
      expect(
        gradeCourseIdentity(
          _rec(
            course: '示例课程',
            code: '202400000000',
            term: '2025-2026-1',
            grade: '99',
          ),
        ),
        '示例课程|202400000000',
      );
    });
  });
}
