import 'package:flutter/material.dart';

// ==================== 体测成绩计算器 ====================
// 依据《国家学生体质健康标准（2014年修订）》大学生评分标准。
// 单项权重：BMI 15% / 肺活量 15% / 50米 20% / 坐位体前屈 10% /
// 立定跳远 10% / 引体向上(男)·1分钟仰卧起坐(女) 10% / 1000米(男)·800米(女) 20%。
// 年级分两组：大一大二、大三大四（阈值不同）。数据来自官方评分表，
// 如需微调可直接改下面两张表。table 每项 [阈值, 单项得分]，按得分降序。

// 表 key 后缀与 _FitItemDef.key 一一对应：
// _lung/_50/_reach/_jump/_pu/_1000/_800。注意：男生引体/女生仰卧起坐都用 '_pu'。
const Map<String, List<List<double>>> fitHigher = {
  'M12_lung': [
    [5040, 100],
    [4920, 95],
    [4800, 90],
    [4550, 85],
    [4300, 80],
    [4180, 78],
    [4060, 76],
    [3940, 74],
    [3820, 72],
    [3700, 70],
    [3580, 68],
    [3460, 66],
    [3340, 64],
    [3220, 62],
    [3100, 60],
    [2940, 50],
    [2780, 40],
    [2620, 30],
    [2460, 20],
    [2300, 10],
  ],
  'M34_lung': [
    [5140, 100],
    [5020, 95],
    [4900, 90],
    [4650, 85],
    [4400, 80],
    [4280, 78],
    [4160, 76],
    [4040, 74],
    [3920, 72],
    [3800, 70],
    [3680, 68],
    [3560, 66],
    [3440, 64],
    [3320, 62],
    [3200, 60],
    [3030, 50],
    [2860, 40],
    [2690, 30],
    [2520, 20],
    [2350, 10],
  ],
  'F12_lung': [
    [3400, 100],
    [3350, 95],
    [3300, 90],
    [3150, 85],
    [3000, 80],
    [2900, 78],
    [2800, 76],
    [2700, 74],
    [2600, 72],
    [2500, 70],
    [2400, 68],
    [2300, 66],
    [2200, 64],
    [2100, 62],
    [2000, 60],
    [1960, 50],
    [1920, 40],
    [1880, 30],
    [1840, 20],
    [1800, 10],
  ],
  'F34_lung': [
    [3450, 100],
    [3400, 95],
    [3350, 90],
    [3200, 85],
    [3050, 80],
    [2950, 78],
    [2850, 76],
    [2750, 74],
    [2650, 72],
    [2550, 70],
    [2450, 68],
    [2350, 66],
    [2250, 64],
    [2150, 62],
    [2050, 60],
    [2010, 50],
    [1970, 40],
    [1930, 30],
    [1890, 20],
    [1850, 10],
  ],
  'M12_reach': [
    [24.9, 100],
    [23.1, 95],
    [21.3, 90],
    [19.5, 85],
    [17.7, 80],
    [16.3, 78],
    [14.9, 76],
    [13.5, 74],
    [12.1, 72],
    [10.7, 70],
    [9.3, 68],
    [7.9, 66],
    [6.5, 64],
    [5.1, 62],
    [3.7, 60],
    [2.7, 50],
    [1.7, 40],
    [0.7, 30],
    [-0.3, 20],
    [-1.3, 10],
  ],
  'M34_reach': [
    [25.1, 100],
    [23.3, 95],
    [21.5, 90],
    [19.9, 85],
    [18.2, 80],
    [16.8, 78],
    [15.4, 76],
    [14.0, 74],
    [12.6, 72],
    [11.2, 70],
    [9.8, 68],
    [8.4, 66],
    [7.0, 64],
    [5.6, 62],
    [4.2, 60],
    [3.2, 50],
    [2.2, 40],
    [1.2, 30],
    [0.2, 20],
    [-0.8, 10],
  ],
  'F12_reach': [
    [25.8, 100],
    [24.0, 95],
    [22.2, 90],
    [20.6, 85],
    [19.0, 80],
    [17.7, 78],
    [16.4, 76],
    [15.1, 74],
    [13.8, 72],
    [12.5, 70],
    [11.2, 68],
    [9.9, 66],
    [8.6, 64],
    [7.3, 62],
    [6.0, 60],
    [5.2, 50],
    [4.4, 40],
    [3.6, 30],
    [2.8, 20],
    [2.0, 10],
  ],
  'F34_reach': [
    [26.3, 100],
    [24.4, 95],
    [22.4, 90],
    [21.0, 85],
    [19.5, 80],
    [18.2, 78],
    [16.9, 76],
    [15.6, 74],
    [14.3, 72],
    [13.0, 70],
    [11.7, 68],
    [10.4, 66],
    [9.1, 64],
    [7.8, 62],
    [6.5, 60],
    [5.7, 50],
    [4.9, 40],
    [4.1, 30],
    [3.3, 20],
    [2.5, 10],
  ],
  'M12_jump': [
    [273, 100],
    [268, 95],
    [263, 90],
    [256, 85],
    [248, 80],
    [244, 78],
    [240, 76],
    [236, 74],
    [232, 72],
    [228, 70],
    [224, 68],
    [220, 66],
    [216, 64],
    [212, 62],
    [208, 60],
    [203, 50],
    [198, 40],
    [193, 30],
    [188, 20],
    [183, 10],
  ],
  'M34_jump': [
    [275, 100],
    [270, 95],
    [265, 90],
    [258, 85],
    [250, 80],
    [246, 78],
    [242, 76],
    [238, 74],
    [234, 72],
    [230, 70],
    [226, 68],
    [222, 66],
    [218, 64],
    [214, 62],
    [210, 60],
    [205, 50],
    [200, 40],
    [195, 30],
    [190, 20],
    [185, 10],
  ],
  'F12_jump': [
    [207, 100],
    [201, 95],
    [195, 90],
    [188, 85],
    [181, 80],
    [178, 78],
    [175, 76],
    [172, 74],
    [169, 72],
    [166, 70],
    [163, 68],
    [160, 66],
    [157, 64],
    [154, 62],
    [151, 60],
    [146, 50],
    [141, 40],
    [136, 30],
    [131, 20],
    [126, 10],
  ],
  'F34_jump': [
    [208, 100],
    [202, 95],
    [196, 90],
    [189, 85],
    [182, 80],
    [179, 78],
    [176, 76],
    [173, 74],
    [170, 72],
    [167, 70],
    [164, 68],
    [161, 66],
    [158, 64],
    [155, 62],
    [152, 60],
    [147, 50],
    [142, 40],
    [137, 30],
    [132, 20],
    [127, 10],
  ],
  // 男引体向上：M12 缺 14(76)、M34 缺 15(76)，已在下方补齐。
  'M12_pu': [
    [19, 100],
    [18, 95],
    [17, 90],
    [16, 85],
    [15, 80],
    [14, 76],
    [13, 72],
    [12, 68],
    [11, 64],
    [10, 60],
    [9, 50],
    [8, 40],
    [7, 30],
    [6, 20],
    [5, 10],
  ],
  'M34_pu': [
    [20, 100],
    [19, 95],
    [18, 90],
    [17, 85],
    [16, 80],
    [15, 76],
    [14, 72],
    [13, 68],
    [12, 64],
    [11, 60],
    [10, 50],
    [9, 40],
    [8, 30],
    [7, 20],
    [6, 10],
  ],
  // 女 1 分钟仰卧起坐
  'F12_pu': [
    [56, 100],
    [54, 95],
    [52, 90],
    [49, 85],
    [46, 80],
    [44, 78],
    [42, 76],
    [40, 74],
    [38, 72],
    [36, 70],
    [34, 68],
    [32, 66],
    [30, 64],
    [28, 62],
    [26, 60],
    [24, 50],
    [22, 40],
    [20, 30],
    [18, 20],
    [16, 10],
  ],
  'F34_pu': [
    [57, 100],
    [55, 95],
    [53, 90],
    [50, 85],
    [47, 80],
    [45, 78],
    [43, 76],
    [41, 74],
    [39, 72],
    [37, 70],
    [35, 68],
    [33, 66],
    [31, 64],
    [29, 62],
    [27, 60],
    [25, 50],
    [23, 40],
    [21, 30],
    [19, 20],
    [17, 10],
  ],
};

const Map<String, List<List<double>>> fitLower = {
  'M12_50': [
    [6.7, 100],
    [6.8, 95],
    [6.9, 90],
    [7.0, 85],
    [7.1, 80],
    [7.3, 78],
    [7.5, 76],
    [7.7, 74],
    [7.9, 72],
    [8.1, 70],
    [8.3, 68],
    [8.5, 66],
    [8.7, 64],
    [8.9, 62],
    [9.1, 60],
    [9.3, 50],
    [9.5, 40],
    [9.7, 30],
    [9.9, 20],
    [10.1, 10],
  ],
  'M34_50': [
    [6.6, 100],
    [6.7, 95],
    [6.8, 90],
    [6.9, 85],
    [7.0, 80],
    [7.2, 78],
    [7.4, 76],
    [7.6, 74],
    [7.8, 72],
    [8.0, 70],
    [8.2, 68],
    [8.4, 66],
    [8.6, 64],
    [8.8, 62],
    [9.0, 60],
    [9.2, 50],
    [9.4, 40],
    [9.6, 30],
    [9.8, 20],
    [10.0, 10],
  ],
  'F12_50': [
    [7.5, 100],
    [7.6, 95],
    [7.7, 90],
    [8.0, 85],
    [8.3, 80],
    [8.5, 78],
    [8.7, 76],
    [8.9, 74],
    [9.1, 72],
    [9.3, 70],
    [9.5, 68],
    [9.7, 66],
    [9.9, 64],
    [10.1, 62],
    [10.3, 60],
    [10.5, 50],
    [10.7, 40],
    [10.9, 30],
    [11.1, 20],
    [11.3, 10],
  ],
  'F34_50': [
    [7.4, 100],
    [7.5, 95],
    [7.6, 90],
    [7.9, 85],
    [8.2, 80],
    [8.4, 78],
    [8.6, 76],
    [8.8, 74],
    [9.0, 72],
    [9.2, 70],
    [9.4, 68],
    [9.6, 66],
    [9.8, 64],
    [10.0, 62],
    [10.2, 60],
    [10.4, 50],
    [10.6, 40],
    [10.8, 30],
    [11.0, 20],
    [11.2, 10],
  ],
  'M12_1000': [
    [197, 100],
    [202, 95],
    [207, 90],
    [214, 85],
    [222, 80],
    [227, 78],
    [232, 76],
    [237, 74],
    [242, 72],
    [247, 70],
    [252, 68],
    [257, 66],
    [262, 64],
    [267, 62],
    [272, 60],
    [292, 50],
    [312, 40],
    [332, 30],
    [352, 20],
    [372, 10],
  ],
  'M34_1000': [
    [195, 100],
    [200, 95],
    [205, 90],
    [212, 85],
    [220, 80],
    [225, 78],
    [230, 76],
    [235, 74],
    [240, 72],
    [245, 70],
    [250, 68],
    [255, 66],
    [260, 64],
    [265, 62],
    [270, 60],
    [290, 50],
    [310, 40],
    [330, 30],
    [350, 20],
    [370, 10],
  ],
  'F12_800': [
    [198, 100],
    [204, 95],
    [210, 90],
    [217, 85],
    [224, 80],
    [229, 78],
    [234, 76],
    [239, 74],
    [244, 72],
    [249, 70],
    [254, 68],
    [259, 66],
    [264, 64],
    [269, 62],
    [274, 60],
    [284, 50],
    [294, 40],
    [304, 30],
    [314, 20],
    [324, 10],
  ],
  'F34_800': [
    [196, 100],
    [202, 95],
    [208, 90],
    [215, 85],
    [222, 80],
    [227, 78],
    [232, 76],
    [237, 74],
    [242, 72],
    [247, 70],
    [252, 68],
    [257, 66],
    [262, 64],
    [267, 62],
    [272, 60],
    [282, 50],
    [292, 40],
    [302, 30],
    [312, 20],
    [322, 10],
  ],
};

/// 根据得分返回等级名（优秀/良好/及格/不及格）。null 返回 '—'。
String scoreLevel(double? s) {
  if (s == null) return '—';
  if (s >= 90) return '优秀';
  if (s >= 80) return '良好';
  if (s >= 60) return '及格';
  return '不及格';
}

/// 根据得分返回等级对应色（与分数色一致：60+ 绿, 50-59 黄, <50 红）。
Color levelColor(BuildContext context, double? s) =>
    _scoreColorStatic(context, s);

Color _scoreColorStatic(BuildContext context, double? s) {
  final colorScheme = Theme.of(context).colorScheme;
  if (s == null) return colorScheme.onSurfaceVariant;
  if (s >= 60) return colorScheme.tertiary;
  if (s >= 50) return colorScheme.primary;
  return colorScheme.error;
}

/// 根据评分表与实测值算单项得分（区间内线性插值）。higherBetter=true 表示越大分越高。
double fitScore(List<List<double>> table, double value, bool higherBetter) {
  if (value.isNaN) return 0;
  if (higherBetter) {
    for (int i = 0; i < table.length; i++) {
      if (value >= table[i][0]) {
        if (i == 0) return table[0][1];
        final hi = table[i - 1];
        final lo = table[i];
        if (value >= hi[0]) return hi[1];
        final t = (value - lo[0]) / (hi[0] - lo[0]);
        return lo[1] + t * (hi[1] - lo[1]);
      }
    }
    // 实测值低于最低阈值（含填 0）：低于最低档不给 10 分保底，记 0 分。
    return 0;
  } else {
    for (int i = 0; i < table.length; i++) {
      if (value <= table[i][0]) {
        if (i == 0) return table[0][1];
        final hi = table[i - 1];
        final lo = table[i];
        if (value <= hi[0]) return hi[1];
        final t = (lo[0] - value) / (lo[0] - hi[0]);
        return lo[1] + t * (hi[1] - lo[1]);
      }
    }
    // 实测值高于最高阈值（含填 0）：高于最高档记 0 分。
    return 0;
  }
}

/// BMI 单项得分（按官方分档，不插值）。
/// 男生：正常 17.9~23.9=100, 低体重 ≤17.8=80, 超重 24.0~27.9=80, 肥胖 ≥28.0=60
/// 女生：正常 17.2~23.9=100, 低体重 ≤17.1=80, 超重 24.0~27.9=80, 肥胖 ≥28.0=60
int bmiScore(double bmi, bool isMale) {
  if (bmi <= 0) return 0;
  // 端点用"半开区间"判定：低体重段含上限，正常段含下限，避免边界值反复。
  // 男生低体重上限 17.8, 女生 17.1；肥胖下限 28.0。
  if (isMale) {
    if (bmi < 17.9) return 80; // 低体重（≤17.8）
    if (bmi <= 23.9) return 100; // 正常 17.9~23.9
    if (bmi < 28.0) return 80; // 超重 24.0~27.9
    return 60; // 肥胖 ≥28.0
  } else {
    if (bmi < 17.2) return 80; // 低体重（≤17.1）
    if (bmi <= 23.9) return 100; // 正常 17.2~23.9
    if (bmi < 28.0) return 80; // 超重 24.0~27.9
    return 60; // 肥胖 ≥28.0
  }
}

class FitnessPage extends StatefulWidget {
  const FitnessPage({super.key});
  @override
  State<FitnessPage> createState() => _FitnessPageState();
}

class _FitItemDef {
  final String key;
  final String label;
  final String unit;
  final double weight;
  final bool higher;
  final bool isRun;
  _FitItemDef(
    this.key,
    this.label,
    this.unit,
    this.weight,
    this.higher, {
    this.isRun = false,
  });
}

class _FitnessPageState extends State<FitnessPage> {
  bool _male = true;
  int _gradeLevel = 1; // 1=大一大二, 2=大三大四
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _lungCtrl = TextEditingController();
  final _run50Ctrl = TextEditingController();
  final _reachCtrl = TextEditingController();
  final _jumpCtrl = TextEditingController();
  final _puCtrl = TextEditingController();
  final _runMinCtrl = TextEditingController();
  final _runSecCtrl = TextEditingController();

  @override
  void dispose() {
    for (final c in [
      _heightCtrl,
      _weightCtrl,
      _lungCtrl,
      _run50Ctrl,
      _reachCtrl,
      _jumpCtrl,
      _puCtrl,
      _runMinCtrl,
      _runSecCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double? get _bmi {
    final h = double.tryParse(_heightCtrl.text);
    final w = double.tryParse(_weightCtrl.text);
    if (h == null || w == null || h <= 0) return null;
    final m = h / 100;
    return w / (m * m);
  }

  String get _prefix => '${_male ? 'M' : 'F'}${_gradeLevel == 1 ? '12' : '34'}';

  TextEditingController _ctrlFor(String key) {
    switch (key) {
      case '_lung':
        return _lungCtrl;
      case '_50':
        return _run50Ctrl;
      case '_reach':
        return _reachCtrl;
      case '_jump':
        return _jumpCtrl;
      case '_pu':
        return _puCtrl;
      default:
        return _lungCtrl;
    }
  }

  /// 计算单个项目得分；未填写返回 null。
  double? _itemScore(String key, bool higher, {bool isRun = false}) {
    double? value;
    if (isRun) {
      final m = double.tryParse(_runMinCtrl.text);
      final s = double.tryParse(_runSecCtrl.text);
      if (m == null || s == null) return null;
      value = m * 60 + s;
    } else {
      value = double.tryParse(_ctrlFor(key).text);
    }
    if (value == null) return null;
    // 填 0（或负数）视为未达标/未填，记 0 分；真实体测成绩不会是 0。
    if (value <= 0) return 0;
    final table = (higher ? fitHigher : fitLower)['$_prefix$key'];
    if (table == null) return null;
    return fitScore(table, value, higher);
  }

  /// 体测总成绩（标准分，满分 100）。任一项目未填则返回 null。
  double? get _total {
    final bmi = _bmi;
    if (bmi == null) return null;
    double sum = bmiScore(bmi, _male) * 0.15;
    for (final it in _items) {
      final sc = it.isRun
          ? _itemScore(it.key, it.higher, isRun: true)
          : _itemScore(it.key, it.higher);
      if (sc == null) return null;
      sum += sc * it.weight;
    }
    return sum;
  }

  List<_FitItemDef> get _items {
    if (_male) {
      return [
        _FitItemDef('_lung', '肺活量', 'mL', 0.15, true),
        _FitItemDef('_50', '50米跑', '秒', 0.20, false),
        _FitItemDef('_reach', '坐位体前屈', 'cm', 0.10, true),
        _FitItemDef('_jump', '立定跳远', 'cm', 0.10, true),
        _FitItemDef('_pu', '引体向上', '次', 0.10, true),
        _FitItemDef('_1000', '1000米跑', '分:秒', 0.20, false, isRun: true),
      ];
    }
    return [
      _FitItemDef('_lung', '肺活量', 'mL', 0.15, true),
      _FitItemDef('_50', '50米跑', '秒', 0.20, false),
      _FitItemDef('_reach', '坐位体前屈', 'cm', 0.10, true),
      _FitItemDef('_jump', '立定跳远', 'cm', 0.10, true),
      _FitItemDef('_pu', '1分钟仰卧起坐', '次', 0.10, true),
      _FitItemDef('_800', '800米跑', '分:秒', 0.20, false, isRun: true),
    ];
  }

  Color _scoreColor(BuildContext context, double? s) {
    final colorScheme = Theme.of(context).colorScheme;
    if (s == null) return colorScheme.onSurfaceVariant;
    if (s >= 60) return colorScheme.tertiary;
    if (s >= 50) return colorScheme.primary;
    return colorScheme.error;
  }

  Widget _numField(TextEditingController c, String label, String unit) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        suffixText: unit.isEmpty ? null : unit,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (_) => setState(() {}),
    );
  }

  Widget _buildItemCard(_FitItemDef it) {
    final score = it.isRun
        ? _itemScore(it.key, it.higher, isRun: true)
        : _itemScore(it.key, it.higher);
    final hasValue = it.isRun
        ? (_runMinCtrl.text.isNotEmpty || _runSecCtrl.text.isNotEmpty)
        : _ctrlFor(it.key).text.isNotEmpty;
    final level = scoreLevel(score);
    final colorScheme = Theme.of(context).colorScheme;
    final scoreCol = _scoreColor(context, score);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    it.label,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (it.isRun)
                    Row(
                      children: [
                        SizedBox(
                          width: 64,
                          child: _numField(_runMinCtrl, '分', ''),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text(':'),
                        ),
                        SizedBox(
                          width: 64,
                          child: _numField(_runSecCtrl, '秒', ''),
                        ),
                      ],
                    )
                  else
                    SizedBox(
                      width: 150,
                      child: _numField(_ctrlFor(it.key), '成绩', it.unit),
                    ),
                ],
              ),
            ),
            // 右侧：得分（上方大）+ 等级（下方小）
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scoreCol.withAlpha(38),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    hasValue && score != null ? score.toStringAsFixed(0) : '—',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: scoreCol,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  level,
                  style: TextStyle(
                    fontSize: 11,
                    color: scoreCol,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 弹出「体测评分标准」详细划分：权重、总分等级、BMI 分档、各单项评分曲线。
  void _showScoringDetails() {
    final isMale = _male;
    final gradeLabel = _gradeLevel == 1 ? '大一大二' : '大三大四';
    final items = _items;
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final colorScheme = Theme.of(ctx).colorScheme;
        var selected = 0;
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final it = items[selected];
            final table =
                (it.higher ? fitHigher : fitLower)['$_prefix${it.key}'] ??
                const <List<double>>[];
            return AlertDialog(
              title: const Text('体测评分标准'),
              content: SizedBox(
                width: double.maxFinite,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '当前：${isMale ? '男生' : '女生'} · $gradeLabel',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _sectionLabel(ctx, '单项权重'),
                      const Text(
                        'BMI 15% · 肺活量 15% · 50米跑 20% · 坐位体前屈 10% · '
                        '立定跳远 10% · 引体向上(男)/仰卧起坐(女) 10% · '
                        '1000米(男)/800米(女) 20%',
                      ),
                      const SizedBox(height: 12),
                      _sectionLabel(ctx, '总分等级'),
                      const Text(
                        '优秀 ≥90 分 · 良好 ≥80 分 · 及格 ≥60 分 · 不及格 <60 分',
                      ),
                      const SizedBox(height: 12),
                      _sectionLabel(ctx, 'BMI 评分（${isMale ? '男' : '女'}）'),
                      Text(
                        isMale
                            ? '正常 17.9~23.9 = 100 分 · 低体重 ≤17.8 = 80 分 · '
                                  '超重 24.0~27.9 = 80 分 · 肥胖 ≥28.0 = 60 分'
                            : '正常 17.2~23.9 = 100 分 · 低体重 ≤17.1 = 80 分 · '
                                  '超重 24.0~27.9 = 80 分 · 肥胖 ≥28.0 = 60 分',
                      ),
                      const SizedBox(height: 16),
                      _sectionLabel(ctx, '各项目评分曲线'),
                      const SizedBox(height: 8),
                      GridView.count(
                        crossAxisCount: 3,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        mainAxisSpacing: 6,
                        crossAxisSpacing: 6,
                        childAspectRatio: 3.4,
                        children: [
                          for (var i = 0; i < items.length; i++)
                            _itemButton(
                              ctx,
                              selected == i,
                              () => setDialogState(() => selected = i),
                              items[i],
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '${it.label}（${it.unit}）',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      _buildScoreTable(ctx, it),
                      const SizedBox(height: 8),
                      Text(
                        _scoreSummary(it),
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('知道了'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _sectionLabel(BuildContext context, String text) {
    return Text(
      text,
      style: TextStyle(
        fontWeight: FontWeight.bold,
        fontSize: 14,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }

  /// 等宽的评分项目选择按钮：选中态用背景色区分、不出现 √，避免字数不一导致错落。
  Widget _itemButton(
    BuildContext ctx,
    bool isSelected,
    VoidCallback onTap,
    _FitItemDef item,
  ) {
    final colorScheme = Theme.of(ctx).colorScheme;
    return Material(
      color: isSelected
          ? colorScheme.primaryContainer
          : colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Center(
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isSelected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }

  /// 满分 / 及格 标准一句话说明。
  String _scoreSummary(_FitItemDef it) {
    final table = (it.higher ? fitHigher : fitLower)['$_prefix${it.key}'];
    if (table == null || table.isEmpty) return '';
    final cmp = it.higher ? '≥' : '≤';
    final full = table.first;
    final pass = table.firstWhere((r) => r[1] <= 60, orElse: () => table.last);
    return '满分（100分）：$cmp${_formatThreshold(it, full[0])} · '
        '及格（60分）：$cmp${_formatThreshold(it, pass[0])}';
  }

  /// 对称美观的「成绩 → 得分」表格：两列（成绩 | 得分），每条成绩一行。
  Widget _buildScoreTable(BuildContext ctx, _FitItemDef it) {
    final table = (it.higher ? fitHigher : fitLower)['$_prefix${it.key}'];
    if (table == null || table.isEmpty) return const Text('暂无数据');
    final colorScheme = Theme.of(ctx).colorScheme;

    Widget cell(String text, {bool header = false}) {
      return Padding(
        padding: EdgeInsets.symmetric(
          vertical: header ? 8 : 6,
          horizontal: 6,
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: header ? FontWeight.bold : FontWeight.normal,
            color: header
                ? colorScheme.onSurface
                : colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colorScheme.outlineVariant.withAlpha(140)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Table(
          columnWidths: const {
            0: FlexColumnWidth(3),
            1: FlexColumnWidth(2),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          border: TableBorder(
            horizontalInside: BorderSide(
              color: colorScheme.outlineVariant.withAlpha(120),
              width: 0.5,
            ),
            verticalInside: BorderSide(
              color: colorScheme.outlineVariant.withAlpha(120),
              width: 0.5,
            ),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
              ),
              children: [
                cell('成绩', header: true),
                cell('得分', header: true),
              ],
            ),
            for (var i = 0; i < table.length; i++)
              TableRow(
                decoration: i.isEven
                    ? null
                    : BoxDecoration(
                        color: colorScheme.surfaceContainerHighest.withAlpha(50),
                      ),
                children: [
                  cell(_formatThreshold(it, table[i][0])),
                  cell('${table[i][1].toInt()}'),
                ],
              ),
          ],
        ),
      ),
    );
  }

  String _formatThreshold(_FitItemDef it, double v) {
    if (it.isRun) {
      final total = v.round();
      return '${total ~/ 60}分${(total % 60).toString().padLeft(2, '0')}秒';
    }
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bmi = _bmi;
    final bmiSc = bmi == null ? null : bmiScore(bmi, _male).toDouble();
    final total = _total;
    return Scaffold(
      appBar: AppBar(
        title: const Text('体测成绩计算器'),
        actions: [
          IconButton(
            tooltip: '评分标准',
            icon: const Icon(Icons.rule),
            onPressed: _showScoringDetails,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '性别',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  ToggleButtons(
                    isSelected: [_male, !_male],
                    onPressed: (i) => setState(() => _male = i == 0),
                    children: const [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('男'),
                      ),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 20),
                        child: Text('女'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '年级',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      ChoiceChip(
                        label: const Text('大一'),
                        selected: _gradeLevel == 1,
                        onSelected: (_) => setState(() => _gradeLevel = 1),
                      ),
                      ChoiceChip(
                        label: const Text('大二'),
                        selected: _gradeLevel == 1,
                        onSelected: (_) => setState(() => _gradeLevel = 1),
                      ),
                      ChoiceChip(
                        label: const Text('大三'),
                        selected: _gradeLevel == 2,
                        onSelected: (_) => setState(() => _gradeLevel = 2),
                      ),
                      ChoiceChip(
                        label: const Text('大四'),
                        selected: _gradeLevel == 2,
                        onSelected: (_) => setState(() => _gradeLevel = 2),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _numField(_heightCtrl, '身高', 'cm')),
                      const SizedBox(width: 10),
                      Expanded(child: _numField(_weightCtrl, '体重', 'kg')),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Text(
                        'BMI：',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        bmi == null ? '—' : bmi.toStringAsFixed(1),
                        style: TextStyle(
                          fontSize: 16,
                          color: _scoreColor(context, bmiSc),
                        ),
                      ),
                      const SizedBox(width: 16),
                      const Text(
                        'BMI得分：',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      Text(
                        bmi == null ? '—' : '${bmiScore(bmi, _male)}',
                        style: TextStyle(
                          fontSize: 16,
                          color: _scoreColor(context, bmiSc),
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (bmi != null)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _scoreColor(context, bmiSc).withAlpha(38),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            scoreLevel(bmiSc),
                            style: TextStyle(
                              fontSize: 11,
                              color: _scoreColor(context, bmiSc),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '（身高、体重仅用于计算 BMI，不计入体测总分）',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          for (final it in _items) _buildItemCard(it),
          const SizedBox(height: 12),
          Card(
            color: _scoreColor(context, total).withAlpha(30),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    '体测总成绩',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total == null ? '待输入完整数据' : total.toStringAsFixed(1),
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: _scoreColor(context, total),
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (total != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _scoreColor(context, total).withAlpha(51),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '等级 ${scoreLevel(total)}',
                        style: TextStyle(
                          fontSize: 13,
                          color: _scoreColor(context, total),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '评分标准：《国家学生体质健康标准（2014年修订）》大学生组。'
            '总分≥60 绿色，50–59 黄色，<50 红色。单项权重 BMI/肺活量/50米/'
            '坐位体前屈/立定跳远/引体向上(男)或仰卧起坐(女)/1000米(男)或800米(女)'
            ' 分别为 15/15/20/10/10/10/20。',
            style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

