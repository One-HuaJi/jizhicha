// 课表页职责：本地课表读取失败视图、原始 HTML 预览与结构自检面板。
part of 'schedule_page.dart';

mixin _ScheduleDiagnosticsSection on _SchedulePageDataSection {
  Widget _buildErrorView(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: colorScheme.error.withAlpha(140)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline, color: colorScheme.error),
                    const SizedBox(width: 8),
                    Text(
                      '本地课表读取失败',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.error,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: colorScheme.onErrorContainer),
                ),
                if (_debugHtmlPath != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    '已把本次响应的原始 HTML 保存到本地，便于排查：',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: colorScheme.surface,
                      border: Border.all(color: colorScheme.outlineVariant),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SelectableText(
                      _debugHtmlPath!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 16),
                        label: const Text('复制路径'),
                        onPressed: () async {
                          await _copyToClipboard(_debugHtmlPath!);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('路径已复制')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.table_chart, size: 16),
                        label: const Text('复制课表表格'),
                        onPressed: () async {
                          final tables = extractTableBlocks(_lastRawHtml);
                          final text = tables.isEmpty
                              ? '(本页未找到任何 <table>，课表可能是 JS/AJAX 动态加载，请把"结构自检"内容发来)'
                              : tables.join('\n\n');
                          await _copyToClipboard(text);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                tables.isEmpty
                                    ? '本页没有 <table> 表格'
                                    : '已复制 ${tables.length} 个表格',
                              ),
                            ),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.grid_view, size: 16),
                        label: const Text('复制 timetable 表'),
                        onPressed: () async {
                          final tt = extractTableById(
                            _lastRawHtml,
                            'timetable',
                          );
                          if (tt == null) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('本页没有 id="timetable" 的表格')),
                            );
                            return;
                          }
                          await _copyToClipboard(tt);
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制 #timetable')),
                          );
                        },
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showHtmlPreview
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(
                          _showHtmlPreview ? '收起 HTML 预览' : '展开 HTML 预览',
                        ),
                        onPressed: () => setState(
                          () => _showHtmlPreview = !_showHtmlPreview,
                        ),
                      ),
                      OutlinedButton.icon(
                        icon: Icon(
                          _showDiagnostics
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                        ),
                        label: Text(_showDiagnostics ? '收起结构自检' : '结构自检'),
                        onPressed: () => setState(
                          () => _showDiagnostics = !_showDiagnostics,
                        ),
                      ),
                    ],
                  ),
                  if (_showHtmlPreview) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        border: Border.all(color: colorScheme.outlineVariant),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: SelectableText(
                        _lastRawHtml.length > 4096
                            ? '${_lastRawHtml.substring(0, 4096)}\n\n… (已截断，共 ${_lastRawHtml.length} 字符)'
                            : _lastRawHtml,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  if (_showDiagnostics) ...[
                    const SizedBox(height: 12),
                    _buildDiagnosticsView(),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyToClipboard(String text) async {
    // 避免对 flutter/services 的硬依赖，调用方式与项目其它地方一致
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _buildDiagnosticsView() {
    final diag = scheduleDiagnostics(_lastRawHtml);
    final lines = diag.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        border: Border.all(color: colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制自检'),
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  await _copyToClipboard(lines);
                  if (!context.mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(content: Text('自检内容已复制')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            lines,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ],
      ),
    );
  }

}
