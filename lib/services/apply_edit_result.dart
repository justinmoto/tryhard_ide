class ApplyEditResult {
  const ApplyEditResult({
    required this.ok,
    this.path,
    this.oldContent,
    this.newContent,
    this.error,
  });

  final bool ok;
  final String? path;
  final String? oldContent;
  final String? newContent;
  final String? error;

  static ApplyEditResult fail(String error) =>
      ApplyEditResult(ok: false, error: error);
}
