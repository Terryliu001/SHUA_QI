/// 卷内的一页（规格 §5.2 `wb_page` 表）。
library;

/// 备注：列名是 `idx`（SQL 里 `index` 是关键字），模型里叫 [index] 更自然。
class WbPage {
  const WbPage({
    required this.id,
    required this.workbookId,
    required this.index,
    required this.width,
    required this.height,
  });

  factory WbPage.fromRow(Map<String, Object?> row) {
    return WbPage(
      id: row['id']! as String,
      workbookId: row['workbook_id']! as String,
      index: (row['idx']! as num).toInt(),
      width: (row['w']! as num).toDouble(),
      height: (row['h']! as num).toDouble(),
    );
  }

  final String id;
  final String workbookId;

  /// 0-based。**数据库与模型都存 0-based，界面显示时才 +1**（T1.5 的坑）。
  final int index;

  /// 页面坐标 pt。
  final double width;
  final double height;

  Map<String, Object?> toRow() => <String, Object?>{
    'id': id,
    'workbook_id': workbookId,
    'idx': index,
    'w': width,
    'h': height,
  };

  @override
  String toString() =>
      'WbPage($workbookId#$index ${width.toStringAsFixed(1)}×'
      '${height.toStringAsFixed(1)}pt)';
}
