import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tryhard_ide/services/next_to_react.dart';
import 'package:tryhard_ide/services/ollama_service.dart';

typedef M = NextToReactMigration;

void main() {
  group('route mapping', () {
    test('pages router', () {
      expect(M.routeForPagesFile('index.tsx'), '/');
      expect(M.routeForPagesFile('about.js'), '/about');
      expect(M.routeForPagesFile('blog/index.js'), '/blog');
      expect(M.routeForPagesFile('blog/[slug].tsx'), '/blog/:slug');
      expect(M.routeForPagesFile('docs/[...path].js'), '/docs/*');
      expect(M.routeForPagesFile('shop/[[...all]].js'), '/shop/*');
      expect(M.routeForPagesFile('404.js'), '*');
      expect(M.routeForPagesFile('_app.js'), isNull);
    });

    test('app router', () {
      expect(M.routeForAppFile('page.tsx'), '/');
      expect(M.routeForAppFile('(marketing)/pricing/page.tsx'), '/pricing');
      expect(M.routeForAppFile('blog/[id]/page.tsx'), '/blog/:id');
      expect(M.routeForAppFile('@modal/login/page.tsx'), isNull);
      expect(M.routeForAppFile('feed/(..)photo/page.tsx'), isNull);
      expect(M.routeForAppFile('_private/page.tsx'), isNull);
    });
  });

  group('rewrite rules', () {
    test('link, image, head, env, use client', () {
      const src = '''
'use client';
import Link from 'next/link';
import Image from 'next/image';
import Head from 'next/head';

export default function Nav() {
  const api = process.env.NEXT_PUBLIC_API_URL;
  return (
    <>
      <Head><title>Home</title></Head>
      <Link href="/about" prefetch={false} className="x">About</Link>
      <Link className="y" href={`/blog/\${1}`}>Post</Link>
      <Image src="/logo.png" width={20} height={20} alt="" priority placeholder="blur" />
    </>
  );
}
''';
      final r = M.applyRules(src);
      expect(r.applied, containsAll(['use client', 'env', 'next/link', 'next/image', 'next/head']));
      expect(r.code, isNot(contains('use client')));
      expect(r.code, contains("import { Link as Link } from 'react-router-dom';"));
      expect(r.code, contains('<Link to="/about" className="x">'));
      expect(r.code, contains('<Link className="y" to={`/blog/'));
      expect(r.code, contains('<img src="/logo.png" width={20} height={20} alt="" />'));
      expect(r.code, contains('<><title>Home</title></>'));
      expect(r.code, contains('import.meta.env.VITE_API_URL'));
      expect(M.nextImportRe.hasMatch(r.code), isFalse);
      expect(M.needsModel(r.code, MigrateRole.module), isFalse);
    });

    test('_app becomes a children wrapper', () {
      const src = '''
import '../styles/globals.css';
import type { AppProps } from 'next/app';

export default function MyApp({ Component, pageProps }: AppProps) {
  return <main><Component {...pageProps} /></main>;
}
''';
      final r = M.applyRules(src, role: MigrateRole.appWrapper);
      expect(r.code, contains('function MyApp({ children }: { children: React.ReactNode })'));
      expect(r.code, contains('<main>{children}</main>'));
      expect(M.needsModel(r.code, MigrateRole.appWrapper), isFalse);
    });

    test('server-only APIs still go to the model', () {
      expect(M.needsModel("import { useRouter } from 'next/router';", MigrateRole.page), isTrue);
      expect(M.needsModel('export async function getServerSideProps() {}', MigrateRole.page), isTrue);
      expect(M.needsModel('export const metadata = { title: "x" };', MigrateRole.layout), isTrue);
      expect(M.needsModel('export default async function Page() {}', MigrateRole.page), isTrue);
      expect(M.needsModel('<html><body>{children}</body></html>', MigrateRole.layout), isTrue);
      expect(M.needsModel("'use server';\nexport async function save() {}", MigrateRole.module), isTrue);
      expect(M.needsModel('export default function Page() { return <p/>; }', MigrateRole.page), isFalse);
    });

    test('jsonc tsconfig', () {
      final data = M.parseJsonc('{\n  // comment\n  "compilerOptions": { "paths": { "@/*": ["./src/*"], }, /* x */ },\n}');
      expect(data?['compilerOptions']['paths']['@/*'], ['./src/*']);
    });
  });

  test('plans an App Router project', () {
    final plan = M.planFromFiles(
      root: '/r',
      outputDir: '/r-react',
      aliasTarget: 'src',
      packageJson: {
        'name': 'shop',
        'dependencies': {'next': '14.2.0', 'react': '18.3.1', 'react-dom': '18.3.1', 'zod': '^3.0.0'},
        'devDependencies': {'eslint-config-next': '14.2.0', '@next/bundle-analyzer': '1.0.0'},
      },
      files: [
        'package.json',
        'next.config.mjs',
        'src/app/layout.tsx',
        'src/app/page.tsx',
        'src/app/(shop)/products/layout.tsx',
        'src/app/(shop)/products/[id]/page.tsx',
        'src/app/api/orders/route.ts',
        'src/app/not-found.tsx',
        'src/components/Header.tsx',
        'public/logo.png',
      ],
    );
    expect(plan.usesAppRouter, isTrue);
    expect(plan.typescript, isTrue);
    expect(plan.routes.map((r) => r.path), ['/', '/products/:id', '*']);
    final product = plan.routes.firstWhere((r) => r.path == '/products/:id');
    expect(product.layouts, ['src/app/layout.tsx', 'src/app/(shop)/products/layout.tsx']);
    final skipped = {for (final i in plan.items.where((i) => i.action == MigrateAction.skip)) i.rel};
    expect(skipped, {'package.json', 'next.config.mjs', 'src/app/api/orders/route.ts'});

    final routes = M.routesSource(plan);
    expect(routes, contains("import Page2 from './app/(shop)/products/[id]/page';"));
    expect(
      routes,
      contains('<Route path="/products/:id" element={<Layout1><Layout3><WithParams component={Page2} /></Layout3></Layout1>} />'),
    );

    final pkg = M.packageJson(plan);
    expect(pkg, isNot(contains('"next"')));
    expect(pkg, isNot(contains('eslint-config-next')));
    expect(pkg, isNot(contains('@next/')));
    expect(pkg, contains('"react": "18.3.1"'));
    expect(pkg, contains('"react-router-dom"'));
    expect(pkg, contains('"build": "vite build"'));
    expect(M.viteConfig(plan), contains("new URL('./src', import.meta.url)"));
    expect(M.report(plan, const []), contains('React 18.3.1'));
  });

  test('migrates a Pages Router project end to end (rules only)', () async {
    final tmp = Directory.systemTemp.createTempSync('tryhard_next');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final root = p.join(tmp.path, 'site');
    void put(String rel, String content) {
      final f = File(p.joinAll([root, ...rel.split('/')]));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(content);
    }

    put('package.json', '{"name":"site","dependencies":{"next":"15.0.0","react":"19.0.0","react-dom":"19.0.0"}}');
    put('postcss.config.js', 'module.exports = { plugins: {} };\n');
    put('.env.local', 'NEXT_PUBLIC_API=https://x\nSECRET=1\n');
    put('pages/_app.js', "import '../styles/globals.css';\nexport default function App({ Component, pageProps }) {\n  return <Component {...pageProps} />;\n}\n");
    put('pages/_document.js', 'export default function D() {}\n');
    put('pages/index.js', "import Link from 'next/link';\nexport default function Home() {\n  return <Link href=\"/blog/1\">Post</Link>;\n}\n");
    put('pages/blog/[id].js', "export default function Post() { return <p>post</p>; }\n");
    put('pages/api/hello.js', 'export default function h(req, res) {}\n');
    put('styles/globals.css', 'body { margin: 0; }\n');
    put('public/favicon.ico', 'binary');
    put('node_modules/next/index.js', 'ignored');

    final plan = await M.plan(root);
    expect(plan, isNotNull);
    expect(p.basename(plan!.outputDir), 'site-react');

    final result = await NextToReactMigration(OllamaService(baseUrl: 'http://127.0.0.1:9')).execute(
      plan,
      isCancelled: () => false,
    );
    expect(result.cancelled, isFalse);
    expect(result.leftoverNextImports, isEmpty);
    expect(plan.count(MigrateAction.model), 0);
    expect(plan.items.where((i) => i.failed), isEmpty);

    String read(String rel) => File(p.joinAll([plan.outputDir, ...rel.split('/')])).readAsStringSync();
    bool exists(String rel) => File(p.joinAll([plan.outputDir, ...rel.split('/')])).existsSync();

    expect(read('pages/index.js'), contains('<Link to="/blog/1">'));
    expect(read('pages/_app.js'), contains('{children}'));
    expect(read('.env.local'), 'VITE_API=https://x\nSECRET=1\n');
    expect(exists('postcss.config.cjs'), isTrue);
    expect(exists('postcss.config.js'), isFalse);
    expect(exists('pages/api/hello.js'), isFalse);
    expect(exists('pages/_document.js'), isFalse);
    expect(exists('node_modules/next/index.js'), isFalse);
    expect(exists('public/favicon.ico'), isTrue);
    expect(exists('index.html'), isTrue);
    expect(exists('src/vite-main.jsx'), isTrue);
    expect(exists('MIGRATION.md'), isTrue);
    final routes = read('src/vite-routes.jsx');
    expect(routes, contains('<Route path="/blog/:id" element={<App1><Page2 /></App1>} />'));
    expect(routes, contains("import App1 from '../pages/_app';"));
    expect(routes, isNot(contains('WithParams')));
  });
}
