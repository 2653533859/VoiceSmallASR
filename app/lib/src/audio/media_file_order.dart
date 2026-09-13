/// 媒体文件按自然文件名排序，数字片段按数值比较。
library;

import 'package:path/path.dart' as p;

int compareMediaNames(String a, String b) {
  final pattern = RegExp(r'\d+|\D+');
  final aa = pattern
      .allMatches(p.basename(a).toLowerCase())
      .map((m) => m[0]!)
      .toList();
  final bb = pattern
      .allMatches(p.basename(b).toLowerCase())
      .map((m) => m[0]!)
      .toList();
  for (int i = 0; i < aa.length && i < bb.length; i++) {
    final na = BigInt.tryParse(aa[i]);
    final nb = BigInt.tryParse(bb[i]);
    final order = na != null && nb != null
        ? na.compareTo(nb)
        : aa[i].compareTo(bb[i]);
    if (order != 0) return order;
  }
  final order = aa.length.compareTo(bb.length);
  return order == 0 ? a.compareTo(b) : order;
}
