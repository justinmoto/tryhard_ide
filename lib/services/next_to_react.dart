import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'code_translator.dart';
import 'ollama_service.dart';

/// What happens to one project file during migration.
enum MigrateAction {
  copy('copied'),
  rules('rewritten'),
  model('model'),
  skip('skipped');

  const MigrateAction(this.label);
  final String label;
}

enum MigrateRole { page, layout, appWrapper, notFound, module, asset }

class MigrateItem {
  MigrateItem({
    required this.rel,
    required this.action,
    required this.role,
    this.reason,
  });

  /// Posix-style path relative to the project root.
  final String rel;
  MigrateAction action;
  final MigrateRole role;
  String? reason;
  bool failed = false;
}

class NextRoute {
  const NextRoute({required this.path, required this.file, this.layouts = const []});

  /// react-router path, e.g. `/blog/:id`.
  final String path;
  final String file;

  /// App Router layouts wrapping this page, outermost first.
  final List<String> layouts;
}

class MigrationPlan {
  MigrationPlan({
    required this.root,
    required this.outputDir,
    required this.items,
    required this.routes,
    required this.typescript,
    required this.usesAppRouter,
    required this.usesPagesRouter,
    required this.aliasTarget,
    required this.packageJson,
    this.appWrapper,
  });

  final String root;
  final String outputDir;
  final List<MigrateItem> items;
  final List<NextRoute> routes;
  final bool typescript;
  final bool usesAppRouter;
  final bool usesPagesRouter;

  /// Directory `@/` resolves to, relative to root ('.' or 'src').
  final String aliasTarget;
  final Map<String, dynamic> packageJson;

  /// pages/_app — wraps every Pages Router route.
  final String? appWrapper;

  String get routerLabel => [
        if (usesAppRouter) 'App Router',
        if (usesPagesRouter) 'Pages Router',
      ].join(' + ');

  int count(MigrateAction a) => items.where((i) => i.action == a).length;
}

class BuildError {
  const BuildError({required this.message, this.file});

  /// Error text without stack frames.
  final String message;

  /// Absolute path of the project file to fix, when one could be found.
  final String? file;
}

class MigrationResult {
  const MigrationResult({
    required this.outputDir,
    required this.leftoverNextImports,
    required this.cancelled,
  });

  final String outputDir;

  /// Output files (relative) that still import from `next/*`.
  final List<String> leftoverNextImports;
  final bool cancelled;
}

/// Next.js (Pages or App Router) → React + Vite + react-router-dom.
///
/// Non-destructive: writes a sibling `<name>-react/` folder. Deterministic
/// rewrite rules run first; only files still using Next.js APIs go to the
/// model.
class NextToReactMigration {
  NextToReactMigration(this.ollama);

  final OllamaService ollama;

  static const _skipDirs = {
    'node_modules', '.next', '.git', 'out', 'dist', 'build', '.vercel',
    '.turbo', 'coverage', '.idea', '.vscode',
  };
  static const _codeExts = {'.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs'};
  static const _moduleExts = {'.js', '.jsx', '.ts', '.tsx'};
  static const _maxFiles = 3000;

  // ------------------------------------------------------------- detection

  static Future<Map<String, dynamic>?> readPackageJson(String root) async {
    final f = File(p.join(root, 'package.json'));
    if (!await f.exists()) return null;
    try {
      final data = jsonDecode(await f.readAsString());
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  static bool isNextProject(Map<String, dynamic>? pkg) {
    if (pkg == null) return false;
    for (final key in ['dependencies', 'devDependencies']) {
      final deps = pkg[key];
      if (deps is Map && deps.containsKey('next')) return true;
    }
    return false;
  }

  static Future<MigrationPlan?> plan(String root) async {
    final pkg = await readPackageJson(root);
    if (!isNextProject(pkg)) return null;
    final files = <String>[];
    await _walk(Directory(root), root, files);
    return planFromFiles(
      root: root,
      files: files,
      packageJson: pkg!,
      aliasTarget: await _readAliasTarget(root),
      outputDir: await _uniqueOutputDir(root),
    );
  }

  static Future<void> _walk(Directory dir, String root, List<String> out) async {
    if (out.length >= _maxFiles) return;
    try {
      final entities = await dir.list(followLinks: false).toList();
      entities.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entities) {
        final name = p.basename(e.path);
        if (e is Directory) {
          if (_skipDirs.contains(name)) continue;
          await _walk(e, root, out);
        } else if (e is File) {
          if (name == '.DS_Store') continue;
          out.add(p.relative(e.path, from: root).replaceAll(r'\', '/'));
          if (out.length >= _maxFiles) return;
        }
      }
    } catch (_) {}
  }

  static Future<String> _uniqueOutputDir(String root) async {
    final base = p.join(p.dirname(root), '${p.basename(root)}-react');
    var candidate = base;
    for (var i = 2; await Directory(candidate).exists(); i++) {
      candidate = '$base-$i';
    }
    return candidate;
  }

  /// Reads `"@/*": ["./src/*"]` from tsconfig/jsconfig (comments tolerated).
  static Future<String> _readAliasTarget(String root) async {
    for (final name in ['tsconfig.json', 'jsconfig.json']) {
      final f = File(p.join(root, name));
      if (!await f.exists()) continue;
      final data = parseJsonc(await f.readAsString());
      final paths = (data?['compilerOptions'] as Map?)?['paths'] as Map?;
      final target = (paths?['@/*'] as List?)?.firstOrNull;
      if (target is String) {
        final dir = target.replaceAll(RegExp(r'/?\*$'), '');
        final cleaned = p.posix.normalize(dir.isEmpty ? '.' : dir);
        return cleaned;
      }
    }
    return '.';
  }

  /// JSON with comments and trailing commas. String-aware, because tsconfig
  /// path globs like `"@/*"` look like comment openers.
  static Map<String, dynamic>? parseJsonc(String text) {
    final buf = StringBuffer();
    var i = 0;
    while (i < text.length) {
      final c = text[i];
      if (c == '"') {
        final start = i++;
        while (i < text.length && text[i] != '"') {
          i += text[i] == r'\' ? 2 : 1;
        }
        buf.write(text.substring(start, (i + 1).clamp(0, text.length)));
        i++;
      } else if (text.startsWith('//', i)) {
        final nl = text.indexOf('\n', i);
        i = nl < 0 ? text.length : nl;
      } else if (text.startsWith('/*', i)) {
        final end = text.indexOf('*/', i + 2);
        i = end < 0 ? text.length : end + 2;
      } else {
        buf.write(c);
        i++;
      }
    }
    final noTrailing = buf
        .toString()
        .replaceAllMapped(RegExp(r',(\s*[}\]])'), (m) => m[1]!);
    try {
      final data = jsonDecode(noTrailing);
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------- planning

  static MigrationPlan planFromFiles({
    required String root,
    required List<String> files,
    required Map<String, dynamic> packageJson,
    required String aliasTarget,
    required String outputDir,
  }) {
    final fileSet = files.toSet();
    final items = <MigrateItem>[];
    final routes = <NextRoute>[];
    String? appWrapper;
    var usesApp = false;
    var usesPages = false;
    var typescript = false;

    for (final rel in files) {
      final ext = p.posix.extension(rel).toLowerCase();
      final name = p.posix.basename(rel);
      final stem = p.posix.basenameWithoutExtension(rel);
      if (ext == '.ts' || ext == '.tsx') typescript = true;

      MigrateItem add(MigrateAction a, MigrateRole r, [String? reason]) {
        final item = MigrateItem(rel: rel, action: a, role: r, reason: reason);
        items.add(item);
        return item;
      }

      // Files replaced by generated equivalents or meaningless without Next.
      if (rel == 'package.json' || rel == 'tsconfig.json' || rel == 'jsconfig.json') {
        add(MigrateAction.skip, MigrateRole.asset, 'regenerated for Vite');
        continue;
      }
      if (RegExp(r'^(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb)$').hasMatch(rel)) {
        add(MigrateAction.skip, MigrateRole.asset, 'lockfile — dependencies changed, reinstall');
        continue;
      }
      if (RegExp(r'^next\.config\.\w+$').hasMatch(rel) || rel == 'next-env.d.ts') {
        add(MigrateAction.skip, MigrateRole.asset, 'Next.js config');
        continue;
      }
      if (RegExp(r'^(src/)?middleware\.(js|ts)$').hasMatch(rel)) {
        add(MigrateAction.skip, MigrateRole.asset, 'middleware needs a server');
        continue;
      }
      if (RegExp(r'^\.eslintrc|^eslint\.config\.').hasMatch(name) && p.posix.dirname(rel) == '.') {
        add(MigrateAction.skip, MigrateRole.asset, 'ESLint config (eslint-config-next)');
        continue;
      }

      final pagesRel = _underRouterDir(rel, 'pages');
      final appRel = _underRouterDir(rel, 'app');

      if (pagesRel != null && _moduleExts.contains(ext)) {
        usesPages = true;
        if (pagesRel.startsWith('api/')) {
          add(MigrateAction.skip, MigrateRole.asset, 'API route — needs a backend');
          continue;
        }
        if (pagesRel == '_document$ext') {
          add(MigrateAction.skip, MigrateRole.asset, 'replaced by index.html');
          continue;
        }
        if (pagesRel == '_app$ext') {
          appWrapper = rel;
          add(MigrateAction.copy, MigrateRole.appWrapper);
          continue;
        }
        final route = routeForPagesFile(pagesRel);
        if (route != null) {
          routes.add(NextRoute(path: route, file: rel));
          add(MigrateAction.copy, route == '*' ? MigrateRole.notFound : MigrateRole.page);
          continue;
        }
      }

      if (appRel != null && _moduleExts.contains(ext)) {
        usesApp = true;
        if (stem == 'route') {
          add(MigrateAction.skip, MigrateRole.asset, 'route handler — needs a backend');
          continue;
        }
        if (stem == 'page' || (stem == 'not-found' && !appRel.contains('/'))) {
          final route = stem == 'page' ? routeForAppFile(appRel) : '*';
          if (route == null) {
            add(MigrateAction.skip, MigrateRole.asset, 'parallel/intercepting route');
            continue;
          }
          routes.add(NextRoute(
            path: route,
            file: rel,
            layouts: _layoutChain(rel, appRel, fileSet),
          ));
          add(MigrateAction.copy, stem == 'page' ? MigrateRole.page : MigrateRole.notFound);
          continue;
        }
        if (stem == 'layout') {
          add(MigrateAction.copy, MigrateRole.layout);
          continue;
        }
      }

      add(
        MigrateAction.copy,
        _codeExts.contains(ext) ? MigrateRole.module : MigrateRole.asset,
      );
    }

    // Static routes before dynamic ones, catch-alls last, for readability.
    int rank(String path) => path == '*' ? 3 : (path.contains('*') ? 2 : (path.contains(':') ? 1 : 0));
    routes.sort((a, b) {
      final r = rank(a.path).compareTo(rank(b.path));
      return r != 0 ? r : a.path.compareTo(b.path);
    });

    return MigrationPlan(
      root: root,
      outputDir: outputDir,
      items: items,
      routes: routes,
      typescript: typescript,
      usesAppRouter: usesApp,
      usesPagesRouter: usesPages,
      aliasTarget: aliasTarget,
      packageJson: packageJson,
      appWrapper: appWrapper,
    );
  }

  /// Path inside `pages/` or `app/` (optionally under `src/`), else null.
  static String? _underRouterDir(String rel, String dir) {
    for (final prefix in ['$dir/', 'src/$dir/']) {
      if (rel.startsWith(prefix)) return rel.substring(prefix.length);
    }
    return null;
  }

  static String _segment(String s) {
    final optionalCatchAll = RegExp(r'^\[\[\.\.\.(\w+)\]\]$');
    final catchAll = RegExp(r'^\[\.\.\.(\w+)\]$');
    final dynamic = RegExp(r'^\[(\w+)\]$');
    if (optionalCatchAll.hasMatch(s) || catchAll.hasMatch(s)) return '*';
    final m = dynamic.firstMatch(s);
    return m != null ? ':${m.group(1)}' : s;
  }

  /// `blog/[id].tsx` → `/blog/:id`; `index.js` → `/`; `404.js` → `*`.
  static String? routeForPagesFile(String pagesRel) {
    final noExt = pagesRel.replaceFirst(RegExp(r'\.\w+$'), '');
    final segments = noExt.split('/');
    if (segments.any((s) => s.startsWith('_'))) return null;
    if (noExt == '404') return '*';
    if (segments.last == 'index') segments.removeLast();
    return '/${segments.map(_segment).join('/')}';
  }

  /// `(shop)/blog/[id]/page.tsx` → `/blog/:id`. Null for parallel (`@slot`),
  /// intercepting (`(.)x`) and private (`_x`) segments.
  static String? routeForAppFile(String appRel) {
    final segments = appRel.split('/')..removeLast();
    final out = <String>[];
    for (final s in segments) {
      if (s.startsWith('@') || s.startsWith('_') || RegExp(r'^\(\.+\)').hasMatch(s)) {
        return null;
      }
      if (s.startsWith('(') && s.endsWith(')')) continue;
      out.add(_segment(s));
    }
    return '/${out.join('/')}';
  }

  static List<String> _layoutChain(String rel, String appRel, Set<String> files) {
    final appRoot = rel.substring(0, rel.length - appRel.length); // 'app/' or 'src/app/'
    final dirs = appRel.split('/')..removeLast();
    final out = <String>[];
    for (var depth = 0; depth <= dirs.length; depth++) {
      final dir = '$appRoot${dirs.take(depth).map((d) => '$d/').join()}';
      for (final ext in _moduleExts) {
        final candidate = '${dir}layout$ext';
        if (files.contains(candidate)) {
          out.add(candidate);
          break;
        }
      }
    }
    return out;
  }

  // ------------------------------------------------------------------ rules

  static final nextImportRe = RegExp(
    r'''(?:from\s*['"]next(?:/[^'"]*)?['"]|require\(\s*['"]next(?:/[^'"]*)?['"]\s*\)|import\s*['"]next/)''',
  );

  /// Deterministic Next.js → React rewrites. Returns the new code and the
  /// names of the rules that fired.
  static ({String code, List<String> applied}) applyRules(
    String src, {
    MigrateRole role = MigrateRole.module,
  }) {
    var code = src;
    final applied = <String>[];
    void rule(String name, String Function(String) f) {
      final next = f(code);
      if (next != code) {
        code = next;
        applied.add(name);
      }
    }

    rule('use client', (s) => s.replaceAll(
          RegExp(r'''^\s*['"]use client['"];?[ \t]*\r?\n?''', multiLine: true),
          '',
        ));

    rule('env', (s) => s.replaceAllMapped(
          RegExp(r'process\.env\.NEXT_PUBLIC_(\w+)'),
          (m) => 'import.meta.env.VITE_${m[1]}',
        ));

    rule('next/link', (s) {
      final importRe = RegExp(r'''import\s+(\w+)\s+from\s*['"]next/link['"];?''');
      final m = importRe.firstMatch(s);
      if (m == null) return s;
      final local = m.group(1)!;
      var out = s.replaceFirst(importRe, "import { Link as $local } from 'react-router-dom';");
      final hrefRe = RegExp('<$local\\b([^>]*?)\\shref=');
      String prev;
      do {
        prev = out;
        out = out.replaceAllMapped(hrefRe, (m) => '<$local${m[1]} to=');
      } while (out != prev);
      return out
          .replaceAll(RegExp('\\s(?:prefetch|passHref|legacyBehavior|scroll|shallow)(?:=\\{[^}]*\\})?(?=[\\s/>])'), '');
    });

    rule('next/image', (s) {
      final importRe = RegExp(r'''import\s+(\w+)\s+from\s*['"]next/image['"];?[ \t]*\r?\n?''');
      final m = importRe.firstMatch(s);
      if (m == null) return s;
      final local = m.group(1)!;
      return s
          .replaceFirst(importRe, '')
          .replaceAll(RegExp('<$local\\b'), '<img')
          .replaceAll('</$local>', '')
          .replaceAll(RegExp(r'\s(?:priority|fill|unoptimized)(?:=\{[^}]*\})?(?=[\s/>])'), '')
          .replaceAll(RegExp(r'''\s(?:placeholder|blurDataURL|quality|loader)=(?:"[^"]*"|'[^']*'|\{[^}]*\})'''), '');
    });

    // React 19 hoists <title>/<meta> rendered anywhere into <head>.
    rule('next/head', (s) {
      final importRe = RegExp(r'''import\s+(\w+)\s+from\s*['"]next/head['"];?[ \t]*\r?\n?''');
      final m = importRe.firstMatch(s);
      if (m == null) return s;
      final local = m.group(1)!;
      return s
          .replaceFirst(importRe, '')
          .replaceAll(RegExp('<$local\\s*>'), '<>')
          .replaceAll('</$local>', '</>');
    });

    if (role == MigrateRole.appWrapper) {
      rule('_app', (s) => s
          .replaceAll(RegExp(r'<Component\s*\{\s*\.\.\.pageProps\s*\}\s*/>'), '{children}')
          .replaceAll(RegExp(r'\{\s*Component\s*,\s*pageProps\s*\}'), '{ children }')
          .replaceAll(RegExp(r'''import\s+(?:type\s+)?\{\s*AppProps\s*\}\s+from\s*['"]next/app['"];?[ \t]*\r?\n?'''), '')
          .replaceAll(RegExp(r':\s*AppProps\b'), ': { children: React.ReactNode }'));
    }

    return (code: code, applied: applied);
  }

  /// Whether a file still depends on Next.js after [applyRules].
  static bool needsModel(String code, MigrateRole role) {
    if (nextImportRe.hasMatch(code)) return true;
    if (RegExp(r'''^\s*['"]use server['"]''', multiLine: true).hasMatch(code)) return true;
    if (RegExp(r'\b(getServerSideProps|getStaticProps|getStaticPaths|generateStaticParams|generateMetadata)\b')
        .hasMatch(code)) {
      return true;
    }
    if (role == MigrateRole.page || role == MigrateRole.layout || role == MigrateRole.notFound) {
      if (RegExp(r'export\s+const\s+metadata\b').hasMatch(code)) return true;
      if (RegExp(r'export\s+default\s+async\s+function').hasMatch(code)) return true;
      if (role == MigrateRole.layout && RegExp(r'<html\b').hasMatch(code)) return true;
    }
    if (role == MigrateRole.appWrapper && RegExp(r'\bpageProps\b').hasMatch(code)) return true;
    return false;
  }

  static List<ChatMessage> modelPrompt(
    String code,
    String rel,
    MigrateRole role, {
    String? feedback,
  }) {
    final roleNote = switch (role) {
      MigrateRole.page => 'This file is a route page. Route params come from useParams(); query string from useSearchParams().',
      MigrateRole.layout => 'This file is a layout. It must NOT render <html>, <head> or <body>; render only the wrapper markup around {children}.',
      MigrateRole.appWrapper => 'This was pages/_app. Turn it into a component that takes { children } and renders them where <Component {...pageProps} /> was.',
      MigrateRole.notFound => 'This is the 404 page.',
      _ => 'This is a shared module or component.',
    };
    return [
      const ChatMessage(
        role: 'system',
        content: 'Convert Next.js code to plain React for a Vite single-page app using react-router-dom v6.\n'
            'Rules:\n'
            '- Remove every import from "next" or "next/*".\n'
            '- next/router or next/navigation → useNavigate, useParams, useLocation, useSearchParams from react-router-dom (router.push(x) → navigate(x)).\n'
            '- getServerSideProps / getStaticProps → load the same data inside the component with useState + useEffect; delete getStaticPaths / generateStaticParams.\n'
            '- export const metadata / generateMetadata → render a <title> element in the JSX.\n'
            '- async server components → normal components that fetch in useEffect and show a loading state.\n'
            '- next/font → delete it and its className usage.\n'
            '- next/dynamic → React.lazy with Suspense.\n'
            '- "use server" actions → plain async functions that call fetch() and a // TODO comment naming the backend endpoint needed.\n'
            '- Environment variables use import.meta.env.VITE_*.\n'
            '- Keep the default export, other exports, styling and markup unchanged.\n'
            'Reply with ONLY the complete converted file in one code block.',
      ),
      ChatMessage(
        role: 'user',
        content: 'File: $rel\n$roleNote\n'
            '${feedback == null ? '' : '\nA previous conversion was rejected: $feedback\n'}'
            '\n```\n$code\n```',
      ),
    ];
  }

  // -------------------------------------------------------------- execution

  Future<MigrationResult> execute(
    MigrationPlan plan, {
    String? model,
    required bool Function() isCancelled,
    void Function(int done, int total, MigrateItem item)? onProgress,

    /// Retry rounds for files that still import `next/*`.
    int autoFixPasses = 1,
  }) async {
    final out = Directory(plan.outputDir);
    await out.create(recursive: true);
    final total = plan.items.length;
    var done = 0;

    for (final item in plan.items) {
      if (isCancelled()) {
        return MigrationResult(
          outputDir: plan.outputDir,
          leftoverNextImports: const [],
          cancelled: true,
        );
      }
      onProgress?.call(done, total, item);
      if (item.action != MigrateAction.skip) {
        try {
          await _migrateFile(plan, item, model);
        } catch (e) {
          item.failed = true;
          item.reason = '$e';
        }
      }
      done++;
    }
    if (plan.items.isNotEmpty) onProgress?.call(done, total, plan.items.last);

    await _writeScaffold(plan);
    var leftovers = await leftoverNextImports(plan.outputDir);
    for (var pass = 0; pass < autoFixPasses && leftovers.isNotEmpty; pass++) {
      if (isCancelled()) break;
      await _autoFixLeftovers(plan, leftovers, model, onProgress);
      leftovers = await leftoverNextImports(plan.outputDir);
    }
    await File(p.join(plan.outputDir, 'MIGRATION.md'))
        .writeAsString(report(plan, leftovers));

    return MigrationResult(
      outputDir: plan.outputDir,
      leftoverNextImports: leftovers,
      cancelled: false,
    );
  }

  Future<void> _migrateFile(MigrationPlan plan, MigrateItem item, String? model) async {
    final src = File(p.joinAll([plan.root, ...item.rel.split('/')]));
    var destRel = item.rel;
    final ext = p.posix.extension(item.rel).toLowerCase();
    final name = p.posix.basename(item.rel);

    if (name.startsWith('.env')) {
      final text = await src.readAsString();
      final renamed = text.replaceAllMapped(
        RegExp(r'^(\s*)NEXT_PUBLIC_', multiLine: true),
        (m) => '${m[1]}VITE_',
      );
      if (renamed != text) {
        item.action = MigrateAction.rules;
        item.reason = 'NEXT_PUBLIC_* → VITE_*';
      }
      await _write(plan, destRel, renamed);
      return;
    }

    if (!_codeExts.contains(ext)) {
      final dest = File(p.joinAll([plan.outputDir, ...destRel.split('/')]));
      await dest.parent.create(recursive: true);
      await src.copy(dest.path);
      return;
    }

    var code = await src.readAsString();

    // "type": "module" makes CommonJS config files fail to load in Vite.
    if (ext == '.js' &&
        !destRel.contains('/') &&
        RegExp(r'\bmodule\.exports\b').hasMatch(code)) {
      destRel = '${p.posix.withoutExtension(destRel)}.cjs';
      item.action = MigrateAction.rules;
      item.reason = 'renamed to .cjs (CommonJS in an ES module package)';
    }

    final ruled = applyRules(code, role: item.role);
    if (ruled.applied.isNotEmpty) {
      code = ruled.code;
      item.action = MigrateAction.rules;
      item.reason = ruled.applied.join(', ');
    }

    if (needsModel(code, item.role)) {
      try {
        final reply = await ollama.chat(
          messages: modelPrompt(code, item.rel, item.role),
          model: model,
        );
        final converted = CodeTranslator.extractCode(reply);
        if (converted.trim().isEmpty) throw Exception('empty reply');
        code = converted;
        item.action = MigrateAction.model;
        item.reason = [if (ruled.applied.isNotEmpty) ruled.applied.join(', '), 'model'].join(' + ');
      } on ChatCancelledException {
        rethrow;
      } catch (e) {
        item.failed = true;
        item.reason = 'model failed ($e) — still uses Next.js APIs';
        code = '// TODO(tryhard-migrate): automatic conversion failed; this file still uses Next.js APIs.\n$code';
      }
    }

    await _write(plan, destRel, code);
  }

  /// Re-converts output files the first pass left importing `next/*`,
  /// telling the model exactly which imports remain.
  Future<void> _autoFixLeftovers(
    MigrationPlan plan,
    List<String> leftovers,
    String? model,
    void Function(int done, int total, MigrateItem item)? onProgress,
  ) async {
    final byRel = {for (final i in plan.items) i.rel: i};
    for (var n = 0; n < leftovers.length; n++) {
      final rel = leftovers[n];
      final item = byRel[rel] ??
          MigrateItem(rel: rel, action: MigrateAction.model, role: MigrateRole.module);
      onProgress?.call(n, leftovers.length, item);
      final file = File(p.joinAll([plan.outputDir, ...rel.split('/')]));
      final code = (await file.readAsString())
          .replaceFirst(RegExp(r'^// TODO\(tryhard-migrate\).*\n'), '');
      final imports = {
        for (final m in RegExp(r'''['"](next(?:/[^'"]*)?)['"]''').allMatches(code)) m[1]!,
      };
      try {
        final reply = await ollama.chat(
          messages: modelPrompt(
            code,
            rel,
            item.role,
            feedback: 'it still imports ${imports.join(', ')}. Remove every one of them.',
          ),
          model: model,
        );
        final converted = CodeTranslator.extractCode(reply);
        // Only accept a retry that actually got rid of Next.js.
        if (converted.trim().isEmpty || nextImportRe.hasMatch(converted)) continue;
        await file.writeAsString(converted, flush: true);
        item
          ..failed = false
          ..action = MigrateAction.model
          ..reason = 'model (auto-fixed)';
      } on ChatCancelledException {
        rethrow;
      } catch (_) {
        // Keep the first-pass output; the report lists it as a leftover.
      }
    }
  }

  Future<void> _write(MigrationPlan plan, String rel, String content) async {
    final dest = File(p.joinAll([plan.outputDir, ...rel.split('/')]));
    await dest.parent.create(recursive: true);
    await dest.writeAsString(content, flush: true);
  }

  // --------------------------------------------------------------- scaffold

  static const entryMain = 'src/vite-main';
  static const entryRoutes = 'src/vite-routes';

  Future<void> _writeScaffold(MigrationPlan plan) async {
    final x = plan.typescript ? 'tsx' : 'jsx';
    await _write(plan, 'package.json', packageJson(plan));
    await _write(plan, 'index.html', indexHtml(plan));
    await _write(plan, 'vite.config.js', viteConfig(plan));
    await _write(plan, '$entryMain.$x', mainSource(plan));
    await _write(plan, '$entryRoutes.$x', routesSource(plan));
    if (plan.typescript) {
      await _write(plan, 'tsconfig.json', tsconfig(plan));
      await _write(plan, 'src/vite-env.d.ts', '/// <reference types="vite/client" />\n');
    }
  }

  static String packageJson(MigrationPlan plan) {
    final pkg = Map<String, dynamic>.from(plan.packageJson);
    bool isNextDep(String name) =>
        name == 'next' || name == 'eslint-config-next' || name.startsWith('@next/');
    Map<String, dynamic> clean(Object? deps) => {
          if (deps is Map)
            for (final e in deps.entries)
              if (!isNextDep('${e.key}')) '${e.key}': e.value,
        };
    final deps = clean(pkg['dependencies']);
    final devDeps = clean(pkg['devDependencies']);
    deps.putIfAbsent('react', () => '^19.0.0');
    deps.putIfAbsent('react-dom', () => '^19.0.0');
    deps.putIfAbsent('react-router-dom', () => '^6.28.0');
    devDeps.putIfAbsent('vite', () => '^5.4.0');
    devDeps.putIfAbsent('@vitejs/plugin-react', () => '^4.3.0');
    if (plan.typescript) {
      devDeps.putIfAbsent('typescript', () => '^5.6.0');
      devDeps.putIfAbsent('@types/react', () => '^19.0.0');
      devDeps.putIfAbsent('@types/react-dom', () => '^19.0.0');
    }
    pkg
      ..['name'] = '${pkg['name'] ?? 'app'}-react'
      ..['private'] = true
      ..['type'] = 'module'
      ..['scripts'] = {
        'dev': 'vite',
        'build': 'vite build',
        'preview': 'vite preview',
      }
      ..['dependencies'] = _sorted(deps)
      ..['devDependencies'] = _sorted(devDeps);
    return '${const JsonEncoder.withIndent('  ').convert(pkg)}\n';
  }

  static Map<String, dynamic> _sorted(Map<String, dynamic> m) =>
      {for (final k in (m.keys.toList()..sort())) k: m[k]};

  static String indexHtml(MigrationPlan plan) {
    final x = plan.typescript ? 'tsx' : 'jsx';
    final title = plan.packageJson['name'] ?? 'App';
    return '''<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>$title</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/$entryMain.$x"></script>
  </body>
</html>
''';
  }

  static String viteConfig(MigrationPlan plan) => '''import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { fileURLToPath, URL } from 'node:url';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('${plan.aliasTarget == '.' ? './' : './${plan.aliasTarget}'}', import.meta.url)),
    },
  },
});
''';

  static String tsconfig(MigrationPlan plan) {
    final alias = plan.aliasTarget == '.' ? './*' : './${plan.aliasTarget}/*';
    return '${const JsonEncoder.withIndent('  ').convert({
          'compilerOptions': {
            'target': 'ES2020',
            'lib': ['ES2020', 'DOM', 'DOM.Iterable'],
            'module': 'ESNext',
            'moduleResolution': 'bundler',
            'jsx': 'react-jsx',
            'strict': true,
            'skipLibCheck': true,
            'noEmit': true,
            'isolatedModules': true,
            'resolveJsonModule': true,
            'allowJs': true,
            'esModuleInterop': true,
            'baseUrl': '.',
            'paths': {
              '@/*': [alias],
            },
          },
          'include': ['**/*.ts', '**/*.tsx', '**/*.js', '**/*.jsx'],
          'exclude': ['node_modules', 'dist'],
        })}\n';
  }

  static String mainSource(MigrationPlan plan) {
    final bang = plan.typescript ? '!' : '';
    return '''import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import AppRoutes from './vite-routes';

createRoot(document.getElementById('root')$bang).render(
  <StrictMode>
    <AppRoutes />
  </StrictMode>,
);
''';
  }

  /// Import specifier from `src/vite-routes` to [rel], without extension.
  static String _importPath(String rel) {
    final noExt = p.posix.withoutExtension(rel);
    final r = p.posix.relative(noExt, from: 'src');
    return r.startsWith('.') ? r : './$r';
  }

  static String routesSource(MigrationPlan plan) {
    final imports = <String, String>{}; // rel → identifier
    String ident(String rel, String prefix) =>
        imports.putIfAbsent(rel, () => '$prefix${imports.length}');

    final routeLines = <String>[];
    for (final r in plan.routes) {
      final page = ident(r.file, 'Page');
      // App Router pages receive params as props; Pages Router reads them via hooks.
      var element = _isAppRoute(r) ? '<WithParams component={$page} />' : '<$page />';
      for (final layout in r.layouts.reversed) {
        final l = ident(layout, 'Layout');
        element = '<$l>$element</$l>';
      }
      if (plan.appWrapper != null && !_isAppRoute(r)) {
        final a = ident(plan.appWrapper!, 'App');
        element = '<$a>$element</$a>';
      }
      routeLines.add('        <Route path="${r.path}" element={$element} />');
    }

    final ts = plan.typescript;
    final withParams = plan.routes.any(_isAppRoute);
    final buf = StringBuffer()
      ..writeln(withParams
          ? "import { BrowserRouter, Routes, Route, useParams, useSearchParams } from 'react-router-dom';"
          : "import { BrowserRouter, Routes, Route } from 'react-router-dom';");
    if (ts && withParams) buf.writeln("import type { ComponentType } from 'react';");
    for (final e in imports.entries) {
      buf.writeln("import ${e.value} from '${_importPath(e.key)}';");
    }
    buf
      ..writeln()
      ..writeln('// Generated from the Next.js file-system routes by TryHard IDE.');
    if (withParams) {
      buf
        ..writeln(ts
            ? '// eslint-disable-next-line @typescript-eslint/no-explicit-any\nfunction WithParams({ component: C }: { component: ComponentType<any> }) {'
            : 'function WithParams({ component: C }) {')
        ..writeln('  const params = useParams();')
        ..writeln('  const [searchParams] = useSearchParams();')
        ..writeln('  return <C params={params} searchParams={Object.fromEntries(searchParams)} />;')
        ..writeln('}')
        ..writeln();
    }
    buf
      ..writeln('export default function AppRoutes() {')
      ..writeln('  return (')
      ..writeln('    <BrowserRouter>')
      ..writeln('      <Routes>')
      ..writeAll(routeLines.map((l) => '$l\n'))
      ..writeln('      </Routes>')
      ..writeln('    </BrowserRouter>')
      ..writeln('  );')
      ..writeln('}');
    return buf.toString();
  }

  static bool _isAppRoute(NextRoute r) =>
      _underRouterDir(r.file, 'app') != null;

  // ------------------------------------------------------------ verification

  // ------------------------------------------------------------- build fixes

  static final _ansi = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
  static final _codeFile = RegExp(r'\.(?:[cm]?[jt]sx?)$');

  /// The failing file and error text from `vite build` output, or null when
  /// the output has no recognisable error.
  static BuildError? parseBuildError(List<String> lines, String outputDir) {
    final clean = [for (final l in lines) l.replaceAll(_ansi, '')];
    var start = clean.lastIndexWhere((l) =>
        l.contains('error during build') ||
        l.contains('Build failed') ||
        l.contains('[ERROR]') ||
        RegExp(r'^\s*\[vite[:\]]').hasMatch(l));
    if (start < 0) {
      start = clean.lastIndexWhere((l) => RegExp(r'\berror\b', caseSensitive: false).hasMatch(l));
    }
    if (start < 0) return null;

    // Stack frames are noise for the model and for path matching.
    final message = clean
        .skip(start)
        .where((l) => !RegExp(r'^\s+at\s').hasMatch(l) && !l.startsWith('[exit'))
        .take(25)
        .join('\n')
        .trim();

    final patterns = [
      RegExp(r'^\s*file:\s*(.+?)(?::\d+(?::\d+)?)?\s*$', multiLine: true),
      RegExp(r'imported by "([^"]+)"'),
      RegExp(r'''from ["']([^"']+)["']'''),
      RegExp(r'^\s*(\S+?\.[cm]?[jt]sx?)\s*\(\d+:\d+\)', multiLine: true),
      // esbuild location line: `    src/app/page.tsx:1:9:`
      RegExp(r'^\s*(\S+?\.[cm]?[jt]sx?):\d+:\d+:?\s*$', multiLine: true),
      RegExp(r'''((?:[A-Za-z]:)?[\\/][^\s"':()]+\.[cm]?[jt]sx?)(?=[:\s"')]|$)''', multiLine: true),
    ];
    final root = p.normalize(p.absolute(outputDir));
    for (final re in patterns) {
      for (final m in re.allMatches(message)) {
        final raw = m.group(1)!.trim();
        final abs = p.normalize(p.isAbsolute(raw) ? raw : p.join(root, raw));
        if (!p.isWithin(root, abs) || abs.contains('node_modules')) continue;
        if (!_codeFile.hasMatch(abs) || !File(abs).existsSync()) continue;
        return BuildError(message: message, file: abs);
      }
    }
    return BuildError(message: message);
  }

  /// Asks the model to fix [error.file] for a failed build. Other project
  /// files named in the error are sent as read-only context. Returns the
  /// fixed file's path relative to [outputDir], or null if nothing changed.
  Future<String?> fixBuildError(String outputDir, BuildError error, {String? model}) async {
    final path = error.file;
    if (path == null) return null;
    final rel = p.relative(path, from: outputDir).replaceAll(r'\', '/');
    final code = await File(path).readAsString();

    final related = StringBuffer();
    for (final m in RegExp(r'"([^"]+\.[cm]?[jt]sx?)"').allMatches(error.message)) {
      final other = p.normalize(p.isAbsolute(m[1]!) ? m[1]! : p.join(outputDir, m[1]!));
      if (p.equals(other, path) || !p.isWithin(outputDir, other) || other.contains('node_modules')) continue;
      final f = File(other);
      if (!await f.exists()) continue;
      var text = await f.readAsString();
      if (text.length > 4000) text = '${text.substring(0, 4000)}\n// …truncated';
      related.write('\nRelated file (read-only): ${p.relative(other, from: outputDir).replaceAll(r'\', '/')}\n```\n$text\n```\n');
    }

    final reply = await ollama.chat(
      messages: [
        const ChatMessage(
          role: 'system',
          content: 'You fix build errors in a React + Vite + react-router-dom v6 project that was migrated from Next.js.\n'
              '- Change only what the error requires; keep the rest of the file as is.\n'
              '- No imports from "next" or "next/*".\n'
              '- If an import names something the other file does not export, import what it does export instead.\n'
              'Reply with ONLY the complete fixed file in one code block.',
        ),
        ChatMessage(
          role: 'user',
          content: 'Build error:\n```\n${error.message}\n```\n\nFile to fix: $rel\n```\n$code\n```\n$related',
        ),
      ],
      model: model,
    );
    final fixed = CodeTranslator.extractCode(reply);
    if (fixed.trim().isEmpty || fixed.trim() == code.trim()) return null;
    await File(path).writeAsString(fixed, flush: true);
    return rel;
  }

  static Future<List<String>> leftoverNextImports(String outputDir) async {
    final out = <String>[];
    final files = <String>[];
    await _walk(Directory(outputDir), outputDir, files);
    for (final rel in files) {
      if (!_codeExts.contains(p.posix.extension(rel).toLowerCase())) continue;
      try {
        final code = await File(p.join(outputDir, rel)).readAsString();
        if (nextImportRe.hasMatch(code)) out.add(rel);
      } catch (_) {}
    }
    return out;
  }

  static String report(MigrationPlan plan, List<String> leftovers) {
    final b = StringBuffer()
      ..writeln('# Next.js → React (Vite) migration')
      ..writeln()
      ..writeln('Source: `${plan.root}` (${plan.routerLabel})')
      ..writeln()
      ..writeln('```sh')
      ..writeln('npm install')
      ..writeln('npm run dev')
      ..writeln('```')
      ..writeln()
      ..writeln('## Check')
      ..writeln()
      ..writeln(leftovers.isEmpty
          ? '- ✅ No `next/*` imports left.'
          : '- ⚠️ ${leftovers.length} file(s) still import `next/*`: ${leftovers.map((l) => '`$l`').join(', ')}')
      ..writeln()
      ..writeln('## Routes')
      ..writeln()
      ..writeln('| Path | File |')
      ..writeln('| --- | --- |');
    for (final r in plan.routes) {
      b.writeln('| `${r.path}` | `${r.file}` |');
    }
    b
      ..writeln()
      ..writeln('## Files')
      ..writeln()
      ..writeln('| File | Result | Notes |')
      ..writeln('| --- | --- | --- |');
    for (final i in plan.items) {
      if (i.action == MigrateAction.copy && i.role == MigrateRole.asset) continue;
      final result = i.failed ? 'needs review' : i.action.label;
      b.writeln('| `${i.rel}` | $result | ${i.reason ?? ''} |');
    }
    b
      ..writeln()
      ..writeln('## Not migrated automatically')
      ..writeln()
      ..writeln('- API routes and route handlers need a separate backend (Express, Hono, serverless…).')
      ..writeln('- Server-side rendering, ISR and middleware have no SPA equivalent; data now loads in the browser.')
      ..writeln('- `loading`, `error` and nested `not-found` files are copied but not wired into the router.');
    final react = '${(plan.packageJson['dependencies'] as Map?)?['react'] ?? ''}';
    if (RegExp(r'^\D*1[0-8]\.').hasMatch(react)) {
      b.writeln('- React $react: `<title>` in components only works on React 19+. Upgrade, or set `document.title` instead.');
    }
    return b.toString();
  }
}
