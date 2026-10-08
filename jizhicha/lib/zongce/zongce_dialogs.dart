// 综测页的两个弹窗：智育「从成绩自动计算」课程勾选、体测成绩表导入确认。
//
// 本文件是 `lib/zongce_page.dart` 的 **part**（不是独立库）：拆分只为缩短巨石
// 文件，**不改变任何符号的可见性** —— `_AcademicPickResult` / `_AcademicPickDialog`
// / `_FitnessImportDialog` 本来就是这个库里私有的类。
// ⚠️ part 文件不能有自己的 import，依赖一律写在 `lib/zongce_page.dart` 根部
// （`zongce_academic.dart` 提供 `buildAcademicAuto`/`fmtNum`，`zongce_docx.dart`
// 提供 `SheetColumns`/`FitnessSheetMatch`）。
part of '../zongce_page.dart';

/// 智育自动计算的选择结果。
class _AcademicPickResult {
  final double score;
  final double average;
  final int counted;

  /// 供导出用的算式说明（「共 x 科，（…）/x = 平均分」）。
  final String detail;

  const _AcademicPickResult({
    required this.score,
    required this.average,
    required this.counted,
    this.detail = '',
  });
}

/// 课程勾选弹窗：列出候选课程，自动勾选、允许手动调整，并标出可疑项。
class _AcademicPickDialog extends StatefulWidget {
  const _AcademicPickDialog({required this.grades, required this.term});

  final List<Map<String, String>> grades;
  final String term;

  @override
  State<_AcademicPickDialog> createState() => _AcademicPickDialogState();
}

class _AcademicPickDialogState extends State<_AcademicPickDialog> {
  late AcademicAutoResult _result;

  @override
  void initState() {
    super.initState();
    // 固定用页面所选学期，不再提供「全部学期」——综测是按学期评的。
    _result = buildAcademicAuto(widget.grades, term: widget.term);
  }

  @override
  Widget build(BuildContext context) {
    final avg = _result.average;
    final score = _result.academicScore;
    final nonNumeric = _result.selectedNonNumeric;

    return AlertDialog(
      title: const Text('从成绩自动计算学业成绩'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '学期：${widget.term.isEmpty ? '未选择' : widget.term}',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '已勾选 ${_result.countedCount} 门课，平均分 '
              '${avg == null ? '—' : avg.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 13),
            ),
            Text(
              '学业成绩 = 平均分 × 90% = ${score == null ? '—' : score.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 6),
            Text(
              // 这里是普通 Text，不支持 Markdown；写 **粗体** 会原样显示出星号。
              '细则要求排除体育课、网络通识课、公共选修课、等级课程。'
              '已自动判断并预勾选，请核对下面的列表——'
              '判断依据是课程名与课程性质，可能与学院口径不同。',
              style: TextStyle(
                fontSize: 11,
                height: 1.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (nonNumeric.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '⚠ 有 ${nonNumeric.length} 门课是文字成绩（如「良」），'
                  '无法参与平均，请取消勾选或手动核算。',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            const Divider(),
            Flexible(
              child: _result.courses.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Text('该学期没有可取的成绩。'),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _result.courses.length,
                      itemBuilder: (ctx, i) {
                        final c = _result.courses[i];
                        final suspect = !c.hasNumericScore;
                        return CheckboxListTile(
                          dense: true,
                          value: c.selected,
                          onChanged: (v) {
                            setState(() => c.selected = v ?? false);
                          },
                          title: Text(
                            c.course,
                            style: TextStyle(
                              fontSize: 13,
                              color: suspect
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (c.courseType.isNotEmpty) c.courseType,
                              if (c.rawGrade.isNotEmpty) '成绩 ${c.rawGrade}',
                              if (c.excludedReason.isNotEmpty) c.excludedReason,
                            ].join(' · '),
                            style: const TextStyle(fontSize: 11),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: score == null
              ? null
              : () => Navigator.of(context).pop(
                  _AcademicPickResult(
                    score: score,
                    average: avg!,
                    counted: _result.countedCount,
                    detail: _result.describeCalculation(fmtNum),
                  ),
                ),
          child: const Text('采用这个分数'),
        ),
      ],
    );
  }
}

/// 体测成绩导入确认弹窗：展示识别到的表头与匹配行，让用户确认后再填入。
class _FitnessImportDialog extends StatelessWidget {
  const _FitnessImportDialog({
    required this.cols,
    required this.matches,
    required this.studentId,
    required this.name,
  });

  final SheetColumns cols;
  final List<FitnessSheetMatch> matches;
  final String studentId;
  final String name;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('确认导入体测成绩'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('识别到的表头：', style: TextStyle(fontWeight: FontWeight.w600)),
              Text(
                cols.headerTexts.where((e) => e.trim().isNotEmpty).join(' | '),
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 6),
              Text(
                '筛选条件：学号 = $studentId，姓名 = $name'
                '（两者都必须相同，避免重名误取）',
                style: const TextStyle(fontSize: 12),
              ),
              const Divider(),
              Text(
                matches.length == 1 ? '匹配到 1 行：' : '匹配到 ${matches.length} 行：',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              for (final m in matches)
                Card(
                  margin: const EdgeInsets.only(top: 6),
                  child: ListTile(
                    dense: true,
                    title: Text('${m.studentId}　${m.name}'),
                    subtitle: Text('总分列的值：${m.rawTotal.isEmpty ? '（空）' : m.rawTotal}'),
                    trailing: m.total == null
                        ? const Text('非数字', style: TextStyle(fontSize: 12))
                        : Text(
                            '${m.total}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '确认无误后点「采用」写入体测成绩；若表里有重复行（如补考记录），'
                '请选总分正确的那条。',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: matches.length == 1
              ? () => Navigator.of(context).pop(matches.first)
              : null,
          // 多行匹配时这个按钮是禁用的，按不了；文案要说明"该怎么办"，
          // 而不是旧版的"见下"（按钮上写"见下"用户找不到指向）。
          child: Text(
            matches.length == 1 ? '采用' : '请在下面选择正确的行',
          ),
        ),
        if (matches.length > 1)
          ...matches.asMap().entries.map(
            (e) => TextButton(
              onPressed: () => Navigator.of(context).pop(e.value),
              child: Text('用第 ${e.key + 1} 行（${e.value.rawTotal}）'),
            ),
          ),
      ],
    );
  }
}
