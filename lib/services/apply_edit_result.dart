class ApplyEditResult {
  const ApplyEditResult({
    required this.ok,
    this.path,
    this.oldContent,
    this.newContent,
    this.error,
    this.created = false,
  });

  final bool ok;
  final String? path;
  final String? oldContent;
  final String? newContent;
  final String? error;

  /// The edit created [path]; discarding it deletes the file.
  final bool created;

  static ApplyEditResult fail(String error) =>
      ApplyEditResult(ok: false, error: error);
}
