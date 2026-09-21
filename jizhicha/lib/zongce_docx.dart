// 综测加减分自评表 —— 导出 Word（.docx）。
//
// ── 做法：以官方表为模板，只替换文字 ──────────────────────────────
// 模板是 `assets/templates/zongce_form_template.docx`（用户提供的官方原表）。
// 导出时把它整包读进来，**只改文字与插图**，其余部件（theme / fontTable /
// settings / styles / docProps / 页边距）原样保留。这样字体、字号、边框、
// 列宽、纸张边距全部与官方表一致，不会出现自建表格走样的问题。
//
// ⚠️ 模板里的文字被拆成多个 run（例如「基础分3」+「0」拼成「基础分30」），
// 所以**不能做字符串替换**。正确做法是按单元格整体重建：清掉该格原有的
// <w:p>，再按需要的行数写入新的 <w:p>。这样也顺带解决了「一格多行」与
// 「格内插图」。
//
// ⚠️ 模板的 document.xml 根元素**没有**声明 `a:`（DrawingML）与 `pic:`
// 命名空间，插图片时必须手动补上这两个声明，否则 Word 打不开。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'zongce_model.dart';

/// 模板资源路径。
const String kZongceTemplateAsset =
    'assets/templates/zongce_form_template.docx';

const String _nsA = 'http://schemas.openxmlformats.org/drawingml/2006/main';
const String _nsPic =
    'http://schemas.openxmlformats.org/drawingml/2006/picture';
const String _relImage =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships/image';

/// 转义 XML 特殊字符。
String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// 数值格式化：整数不带小数点，其余去掉多余尾零。
String fmtNum(double v) {
  if (v == v.roundToDouble()) return v.toInt().toString();
  var s = v.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  return s.replaceFirst(RegExp(r'\.$'), '');
}

/// 段落里的一个文本片段（用于保留模板的字重/颜色/下划线）。
class _Run {
  final String text;
  final bool bold;
  final String? color;
  final bool underline;

  const _Run(this.text, {this.bold = false, this.color, this.underline = false});
}

/// 生成 `<w:p>`，样式与模板一致（宋体、居中/左对齐）。
String _pRuns(List<_Run> runs, {String align = 'center', int size = 24}) {
  final buf = StringBuffer('<w:p><w:pPr>');
  if (align.isNotEmpty) buf.write('<w:jc w:val="$align"/>');
  buf.write(
    '<w:rPr><w:rFonts w:hint="eastAsia" w:eastAsia="宋体"/>'
    '<w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr></w:pPr>',
  );
  for (final r in runs) {
    if (r.text.isEmpty) continue;
    buf.write('<w:r><w:rPr><w:rFonts w:hint="eastAsia" w:eastAsia="宋体"/>');
    if (r.bold) buf.write('<w:b/><w:bCs/>');
    if (r.underline) buf.write('<w:u w:val="single"/>');
    if (r.color != null) buf.write('<w:color w:val="${r.color}"/>');
    buf.write('<w:sz w:val="$size"/><w:szCs w:val="$size"/></w:rPr>');
    buf.write('<w:t xml:space="preserve">${_esc(r.text)}</w:t></w:r>');
  }
  buf.write('</w:p>');
  return buf.toString();
}

/// 单行文本段落。
String _p(
  String text, {
  bool bold = false,
  int size = 24,
  String align = 'center',
}) => _pRuns([_Run(text, bold: bold)], align: align, size: size);

/// 把用户录入的加减分记录汇总成「参与情况」描述文字。
///
/// 形如：`① 团培 +5；② 献血 +5`。没有记录时返回空串（表格里留白给手写）。
String describeEntries(ZongceRow r) {
  final parts = <String>[];
  var i = 1;
  for (final e in r.entries) {
    final note = e.note.trim();
    if (note.isEmpty && e.value == 0) continue;
    final sign = e.value >= 0 ? '+' : '';
    final bullet = String.fromCharCode(0x2460 + (i - 1) % 20);
    parts.add(
      note.isEmpty
          ? '$bullet $sign${fmtNum(e.value)}'
          : '$bullet $note $sign${fmtNum(e.value)}',
    );
    i++;
  }
  return parts.join('；');
}

/// 「参与情况」格要显示的段落文本。
///
/// 顺序：基础分 → 自动算出的算式（若有）→ 各条加减分明细 → 截断提示。
/// 基础分在前更贴近官方表的填写习惯，算式紧随其后解释这个分数怎么来的。
List<String> participationLines(ZongceRow r) {
  final lines = <String>['基础分 ${fmtNum(r.base)} 分'];
  // 自动计算留下的算式说明。学业成绩是两行：算式 + 逐科明细。
  // ⚠️ `detail` 可能含换行，必须拆成**多个 <w:p>** —— 单个 <w:p> 里的 \n
  // 在 Word 里不会换行（模板本身也没有用 <w:br/>，是分段实现的）。
  final detail = r.detail.trim();
  if (detail.isNotEmpty) {
    for (final line in detail.split('\n')) {
      final t = line.trim();
      if (t.isNotEmpty) lines.add(t);
    }
  }
  final d = describeEntries(r);
  if (d.isNotEmpty) lines.add(d);
  if (r.isCapped) {
    lines.add('（加分后 ${fmtNum(r.rawScore)}，按满分 ${fmtNum(r.cap!)} 截断）');
  }
  if (r.isFloored) lines.add('（扣分后低于 0，按 0 计）');
  return lines;
}

/// 减分项那一行在「参与情况」里的文字。
///
/// 减分项本身没有基础分，写「基础分 0 分」会让老师困惑；
/// 改成直接说明扣了多少、扣在哪儿。
List<String> deductionLines(ZongceRow r, String targetTitle) {
  final lines = <String>[];
  final d = describeEntries(r);
  final total = r.score; // 允许为负
  if (d.isNotEmpty) {
    lines.add(d);
  } else if (total == 0) {
    lines.add('无');
  }
  if (total != 0) {
    lines.add('合计 ${fmtNum(total)} 分，计入「$targetTitle」');
  }
  return lines;
}

/// 收集模板里所有 `<w:tr>…</w:tr>`。
List<String> _rowsOf(String xml) => RegExp(r'<w:tr>.*?</w:tr>', dotAll: true)
    .allMatches(xml)
    .map((m) => m.group(0)!)
    .toList();

/// 重写一行里指定的几个单元格内容。
///
/// [newContent] 的 key 是列下标（从 0 起），value 是新的单元格内 XML
/// （通常是若干个 `<w:p>`）。原单元格的 `<w:tcPr>` 会被保留，
/// 因此列宽、纵向/横向合并、垂直居中都不受影响。
String _rewriteRow(String tr, Map<int, String> newContent) {
  final cellRe = RegExp(r'<w:tc>.*?</w:tc>', dotAll: true);
  final matches = cellRe.allMatches(tr).toList();
  if (matches.isEmpty) return tr;

  final buf = StringBuffer();
  var cursor = 0;
  for (var i = 0; i < matches.length; i++) {
    final m = matches[i];
    buf.write(tr.substring(cursor, m.start));
    final replacement = newContent[i];
    if (replacement == null) {
      buf.write(m.group(0)!);
    } else {
      final tc = m.group(0)!;
      final pr = RegExp(
        r'<w:tcPr>.*?</w:tcPr>',
        dotAll: true,
      ).firstMatch(tc)?.group(0);
      buf.write('<w:tc>${pr ?? '<w:tcPr/>'}$replacement</w:tc>');
    }
    cursor = m.end;
  }
  buf.write(tr.substring(cursor));
  return buf.toString();
}

/// 替换表格**之前**的第 [index] 个顶层段落（模板里前两段就是标题与基本信息）。
String _replaceLeadingParagraph(String doc, int index, String newXml) {
  final tblStart = doc.indexOf('<w:tbl>');
  final head = tblStart >= 0 ? doc.substring(0, tblStart) : doc;
  final pRe = RegExp(r'<w:p>.*?</w:p>', dotAll: true);
  final matches = pRe.allMatches(head).toList();
  if (index >= matches.length) return doc;
  final m = matches[index];
  return doc.replaceRange(m.start, m.end, newXml);
}

/// 把图片字节编码成 OOXML 的 inline drawing。[cx]/[cy] 单位为 EMU。
String _drawingXml({
  required String relId,
  required int cx,
  required int cy,
  required int docPrId,
}) {
  return '<w:r><w:rPr><w:rFonts w:hint="eastAsia"/></w:rPr><w:drawing>'
      '<wp:inline distT="0" distB="0" distL="0" distR="0">'
      '<wp:extent cx="$cx" cy="$cy"/>'
      '<wp:effectExtent l="0" t="0" r="0" b="0"/>'
      '<wp:docPr id="$docPrId" name="证明图$docPrId"/>'
      '<wp:cNvGraphicFramePr>'
      '<a:graphicFrameLocks xmlns:a="$_nsA" noChangeAspect="1"/>'
      '</wp:cNvGraphicFramePr>'
      '<a:graphic xmlns:a="$_nsA">'
      '<a:graphicData uri="$_nsPic">'
      '<pic:pic xmlns:pic="$_nsPic">'
      '<pic:nvPicPr>'
      '<pic:cNvPr id="$docPrId" name="证明图$docPrId"/>'
      '<pic:cNvPicPr><a:picLocks noChangeAspect="1"/></pic:cNvPicPr>'
      '</pic:nvPicPr>'
      '<pic:blipFill><a:blip r:embed="$relId"/>'
      '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
      '<pic:spPr>'
      '<a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
      '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>'
      '</pic:spPr>'
      '</pic:pic></a:graphicData></a:graphic>'
      '</wp:inline></w:drawing></w:r>';
}

/// 从图片字节读宽高（只解析文件头，不依赖第三方库）。
///
/// 支持 PNG 与 JPEG —— 覆盖手机截图与拍照。
(int, int) decodeImageSize(Uint8List b) {
  // PNG: 89 50 4E 47 0D 0A 1A 0A + IHDR(宽4 + 高4，大端)
  // 读高需要索引 23 有效，故长度至少 24。
  if (b.length >= 24 &&
      b[0] == 0x89 &&
      b[1] == 0x50 &&
      b[2] == 0x4E &&
      b[3] == 0x47) {
    final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
    final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    return (w, h);
  }
  // JPEG: 逐段扫描 SOF 标记
  if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = b[i + 1];
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        i += 2;
        continue;
      }
      final len = (b[i + 2] << 8) | b[i + 3];
      final isSof =
          (marker >= 0xC0 && marker <= 0xC3) ||
          (marker >= 0xC5 && marker <= 0xC7) ||
          (marker >= 0xC9 && marker <= 0xCB);
      if (isSof) {
        final h = (b[i + 5] << 8) | b[i + 6];
        final w = (b[i + 7] << 8) | b[i + 8];
        return (w, h);
      }
      i += 2 + len;
    }
  }
  return (0, 0);
}

/// 依扩展名判断图片类型；扩展名异常时按文件头嗅探。
String _imageExt(String path, Uint8List bytes) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'jpg';
  if (bytes.length > 2 && bytes[0] == 0x89 && bytes[1] == 0x50) return 'png';
  return 'jpg';
}

/// 图片显示尺寸（EMU）。
///
/// 与原图等比缩放：宽度上限 4.5cm、高度上限 6cm。图片与文字同处一格，
/// 限宽既能看清又不至于把整行撑得过分夸张；多张图也不会失控。
(int, int) displaySizeFor(int w, int h) {
  const maxW = 1645920; // 4.5cm
  const maxH = 2194560; // 6cm
  if (w <= 0 || h <= 0) return (maxW, maxH);
  final ratio = w / h;
  var outW = maxW;
  var outH = (outW / ratio).round();
  if (outH > maxH) {
    outH = maxH;
    outW = (outH * ratio).round();
  }
  return (outW, outH);
}

/// 导出结果。
class ZongceDocxResult {
  final Uint8List bytes;
  final int imageCount;

  const ZongceDocxResult(this.bytes, this.imageCount);
}

/// 用官方模板生成综测自评表。
///
/// [templateBytes] 为空时从资源包读取（测试可注入）。
/// [readImage] 为空时用 dart:io 读本地文件。
Future<ZongceDocxResult> buildZongceDocx(
  ZongceForm form, {
  Uint8List? templateBytes,
  Future<Uint8List?> Function(String path)? readImage,
}) async {
  final tpl = ZipDecoder().decodeBytes(
    templateBytes ??
        (await rootBundle.load(kZongceTemplateAsset)).buffer.asUint8List(),
  );

  final parts = <String, List<int>>{};
  for (final f in tpl.files) {
    if (f.isFile) parts[f.name] = List<int>.from(f.content as List<int>);
  }

  var document = utf8.decode(parts['word/document.xml']!);

  // ── 1) 根元素补 DrawingML 命名空间（模板缺，插图片必须补）──
  if (!document.contains('xmlns:a="$_nsA"')) {
    document = document.replaceFirst(
      '<w:document ',
      '<w:document xmlns:a="$_nsA" xmlns:pic="$_nsPic" ',
    );
  }

  // ── 2) 插图准备 ──
  final mediaParts = <String, List<int>>{};
  final relEntries = <String>[];
  var relSeq = 100; // 避开模板已有的 rId1..rId4
  var docPrId = 1;
  var imageCount = 0;

  Future<(String, int, int)?> addImage(String path) async {
    Uint8List? bytes;
    try {
      final loaded = readImage != null
          ? await readImage(path)
          : await File(path).readAsBytes();
      bytes = loaded;
    } catch (_) {
      return null; // 读不到就跳过这张图，不阻断导出
    }
    final data = bytes;
    if (data == null || data.isEmpty) return null;

    final ext = _imageExt(path, data);
    imageCount++;
    final name = 'image$imageCount.$ext';
    mediaParts['word/media/$name'] = List<int>.from(data);
    final relId = 'rId${relSeq++}';
    // 关系表里要保留原有的 rId1..rId4，所以插在 </Relationships> 之前。
    relEntries.add(
      '<Relationship Id="$relId" Type="$_relImage" Target="media/$name"/>',
    );
    final (w, h) = decodeImageSize(data);
    final (cx, cy) = displaySizeFor(w, h);
    return (relId, cx, cy);
  }

  // ── 3) 逐行填字 ──
  var rows = _rowsOf(document);
  if (rows.length < 14) {
    throw StateError('模板行数异常（${rows.length} 行），停止填充以免产出损坏文件');
  }

  final flatRows = form.categories.expand((c) => c.rows).toList();
  if (flatRows.length != 12) {
    throw StateError('模型应有 12 行，实际 ${flatRows.length} 行');
  }

  for (var i = 0; i < flatRows.length; i++) {
    final r = flatRows[i];
    final trIndex = 1 + i; // rows[0] 是表头

    final content = StringBuffer();
    // 减分项走另一套文案：它没有基础分，且分数为负、并入别的行。
    final lines = r.isDeduction
        ? deductionLines(r, r.foldedInto ?? '')
        : participationLines(r);
    for (final line in lines) {
      content.write(_p(line, size: 21, align: 'left'));
    }
    for (final path in r.allImages) {
      final added = await addImage(path);
      if (added == null) continue;
      final (relId, cx, cy) = added;
      content.write(
        '<w:p><w:pPr><w:jc w:val="center"/></w:pPr>'
        '${_drawingXml(relId: relId, cx: cx, cy: cy, docPrId: docPrId++)}'
        '</w:p>',
      );
    }

    rows[trIndex] = _rewriteRow(rows[trIndex], {
      2: content.toString(),
      3: _p(fmtNum(r.score), bold: true),
    });
  }

  // ── 4) 汇总行（rows[13]，6 格）：前 5 格填各育加权分 ──
  final summary = <int, String>{};
  for (var i = 0; i < form.categories.length && i < 5; i++) {
    final c = form.categories[i];
    final pct = (c.weight * 100).round();
    summary[1 + i] =
        '${_p('${c.name.replaceAll('素质', '')}$pct%', size: 24)}'
        '${_p('=', size: 24)}'
        '${_p(fmtNum(c.weighted), size: 24)}';
  }
  rows[13] = _rewriteRow(rows[13], summary);

  // 把改过的行写回文档。
  final rowRe = RegExp(r'<w:tr>.*?</w:tr>', dotAll: true);
  var idx = 0;
  document = document.replaceAllMapped(
    rowRe,
    (m) => idx < rows.length ? rows[idx++] : m.group(0)!,
  );

  // ── 5) 标题与基本信息段（保留模板的标签与样式）──
  final cls = form.className.trim();
  document = _replaceLeadingParagraph(
    document,
    0,
    _pRuns([
      // 标题不带学院名：本表由学生自己填写后交给班主任/辅导员，
      // 学院名由接收方按归档要求处理，表头保持通用。
      const _Run('综合测评加减分自评表  ', bold: true),
      const _Run('（班级：'),
      _Run(cls.isEmpty ? '　　　　　' : cls, underline: true),
      const _Run('）'),
    ], align: 'left'),
  );

  final sid = form.studentId.trim();
  final nm = form.name.trim();
  final tm = form.term.trim();
  document = _replaceLeadingParagraph(
    document,
    1,
    _pRuns([
      _Run('学号：${sid.isEmpty ? '　' * 8 : sid}'),
      _Run('　　姓名：${nm.isEmpty ? '　' * 4 : nm}'),
      if (tm.isNotEmpty) _Run('　　学期：$tm'),
      const _Run('　　最终得分：'),
      // 只写分数，**不带「（合格）」这类等级后缀**（用户要求删掉）。
      // 等级由学院按专业排名另行评定，写在自评表上多余。
      _Run(fmtNum(form.total), bold: true, color: 'FF0000'),
    ], align: 'left'),
  );

  // ── 6) 关系表与 Content_Types ──
  if (relEntries.isNotEmpty) {
    var rels = utf8.decode(parts['word/_rels/document.xml.rels']!);
    rels = rels.replaceFirst(
      '</Relationships>',
      '${relEntries.join()}</Relationships>',
    );
    parts['word/_rels/document.xml.rels'] = utf8.encode(rels);

    var ct = utf8.decode(parts['[Content_Types].xml']!);
    for (final ext in const ['png', 'jpg', 'jpeg']) {
      if (!ct.contains('Extension="$ext"')) {
        ct = ct.replaceFirst(
          '</Types>',
          '<Default Extension="$ext" ContentType="image/$ext"/></Types>',
        );
      }
    }
    parts['[Content_Types].xml'] = utf8.encode(ct);
  }

  if (!document.startsWith('<?xml')) {
    document =
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n$document';
  }
  parts['word/document.xml'] = utf8.encode(document);
  parts.addAll(mediaParts);

  // ── 7) 打包 ──
  final out = Archive();
  for (final e in parts.entries) {
    out.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return ZongceDocxResult(
    Uint8List.fromList(ZipEncoder().encode(out)),
    imageCount,
  );
}
