import 'package:flutter_test/flutter_test.dart';
import 'package:shuaqi/domain/ink/ink_doc.dart';
import 'package:shuaqi/domain/ink/ink_store.dart';
import 'package:shuaqi/infra/ink/ink_writer.dart';

/// T2.4 落盘调度：防抖只写最后一次、flushAll 兜底、失败不丢快照。
void main() {
  InkDoc doc(int n) => InkDoc(
    revision: n,
    strokes: <InkStroke>[
      InkStroke(
        uid: 'u$n',
        points: <InkPoint>[
          InkPoint(x: n.toDouble(), y: n.toDouble()),
        ],
      ),
    ],
  );

  test('同页连续编辑只写最后一次（500ms 防抖语义）', () async {
    final _FakeStore store = _FakeStore();
    final InkWriter writer = InkWriter(
      store: store,
      debounce: const Duration(milliseconds: 30),
    );
    writer.schedule('s', 0, doc(1));
    writer.schedule('s', 0, doc(2));
    writer.schedule('s', 0, doc(3));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(store.saves, 1, reason: '三次编辑只应触发一次落盘');
    expect(store.docs['s#0']!.revision, 3);
    writer.dispose();
  });

  test('flushAll 立刻写掉待写页（生命周期兜底）', () async {
    final _FakeStore store = _FakeStore();
    final InkWriter writer = InkWriter(
      store: store,
      debounce: const Duration(seconds: 10),
    );
    writer.schedule('s', 0, doc(1));
    expect(store.saves, 0);
    await writer.flushAll();
    expect(store.saves, 1);
    expect(store.docs['s#0']!.revision, 1);
    writer.dispose();
  });

  test('保存失败不丢内存快照：下一次 flush 自动重试', () async {
    final _FakeStore store = _FakeStore()..failNext = true;
    final InkWriter writer = InkWriter(
      store: store,
      debounce: Duration.zero,
    );
    writer.schedule('s', 0, doc(7));
    await writer.flushAll();
    expect(store.docs.containsKey('s#0'), isFalse, reason: '第一次写失败');
    await writer.flushAll();
    expect(store.docs['s#0']!.revision, 7, reason: '失败快照要留在待写队列');
    writer.dispose();
  });

  test('同一页的写串行：慢盘上不会旧快照覆盖新快照', () async {
    final _FakeStore store = _FakeStore()
      ..delay = const Duration(milliseconds: 40);
    final InkWriter writer = InkWriter(
      store: store,
      debounce: Duration.zero,
    );
    writer.schedule('s', 0, doc(1));
    final Future<void> first = writer.flush('s', 0);
    writer.schedule('s', 0, doc(2));
    await Future.wait(<Future<void>>[first, writer.flushAll()]);
    expect(store.docs['s#0']!.revision, 2);
    expect(store.saveOrder, <int>[1, 2]);
    writer.dispose();
  });
}

class _FakeStore implements InkStore {
  final Map<String, InkDoc> docs = <String, InkDoc>{};
  final List<int> saveOrder = <int>[];
  int saves = 0;
  int _revision = 0;
  bool failNext = false;
  Duration delay = Duration.zero;

  @override
  Future<InkDoc> load(String sessionId, int pageIndex) async {
    return docs['$sessionId#$pageIndex'] ?? InkDoc.empty;
  }

  @override
  Future<int> save(String sessionId, int pageIndex, InkDoc doc) async {
    saves++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    docs['$sessionId#$pageIndex'] = doc;
    saveOrder.add(doc.revision);
    return ++_revision;
  }
}
