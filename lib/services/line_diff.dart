enum DiffOp { equal, add, remove }

class DiffLine {
  const DiffLine(this.op, this.text);
  final DiffOp op;
  final String text;
}

/// Simple line diff (LCS). Fine for typical source files.
List<DiffLine> diffLines(String before, String after, {int maxLines = 400}) {
  final a = before.replaceAll('\r\n', '\n').split('\n');
  final b = after.replaceAll('\r\n', '\n').split('\n');
  // Drop trailing empty from split
  if (a.isNotEmpty && a.last.isEmpty) a.removeLast();
  if (b.isNotEmpty && b.last.isEmpty) b.removeLast();

  if (a.length > 800 || b.length > 800) {
    return _coarse(a, b, maxLines);
  }

  final n = a.length;
  final m = b.length;
  final dp = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      if (a[i] == b[j]) {
        dp[i][j] = dp[i + 1][j + 1] + 1;
      } else {
        dp[i][j] = dp[i + 1][j] > dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1];
      }
    }
  }

  final raw = <DiffLine>[];
  var i = 0;
  var j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      raw.add(DiffLine(DiffOp.equal, a[i]));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      raw.add(DiffLine(DiffOp.remove, a[i]));
      i++;
    } else {
      raw.add(DiffLine(DiffOp.add, b[j]));
      j++;
    }
  }
  while (i < n) {
    raw.add(DiffLine(DiffOp.remove, a[i++]));
  }
  while (j < m) {
    raw.add(DiffLine(DiffOp.add, b[j++]));
  }

  return _collapseContext(raw, maxLines);
}

List<DiffLine> _coarse(List<String> a, List<String> b, int maxLines) {
  final out = <DiffLine>[];
  for (final line in a.take(maxLines ~/ 2)) {
    out.add(DiffLine(DiffOp.remove, line));
  }
  if (a.length > maxLines ~/ 2) {
    out.add(const DiffLine(DiffOp.equal, '…'));
  }
  for (final line in b.take(maxLines ~/ 2)) {
    out.add(DiffLine(DiffOp.add, line));
  }
  if (b.length > maxLines ~/ 2) {
    out.add(const DiffLine(DiffOp.equal, '…'));
  }
  return out;
}

List<DiffLine> _collapseContext(List<DiffLine> raw, int maxLines) {
  final changed = <int>[];
  for (var i = 0; i < raw.length; i++) {
    if (raw[i].op != DiffOp.equal) changed.add(i);
  }
  if (changed.isEmpty) {
    return [const DiffLine(DiffOp.equal, '(no line changes)')];
  }

  final keep = <bool>[];
  for (var i = 0; i < raw.length; i++) {
    keep.add(false);
  }
  for (final idx in changed) {
    for (var k = idx - 2; k <= idx + 2; k++) {
      if (k >= 0 && k < raw.length) keep[k] = true;
    }
  }

  final out = <DiffLine>[];
  var skipping = false;
  for (var i = 0; i < raw.length; i++) {
    if (!keep[i]) {
      if (!skipping) {
        out.add(const DiffLine(DiffOp.equal, '…'));
        skipping = true;
      }
      continue;
    }
    skipping = false;
    out.add(raw[i]);
    if (out.length >= maxLines) {
      out.add(const DiffLine(DiffOp.equal, '…'));
      break;
    }
  }
  return out;
}
