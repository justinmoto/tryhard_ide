import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/atom-one-dark.dart';
import 'package:flutter_highlight/themes/atom-one-light.dart';
import 'package:highlight/highlight_core.dart';
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/java.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/kotlin.dart';
import 'package:highlight/languages/markdown.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/ruby.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/scss.dart';
import 'package:highlight/languages/swift.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:path/path.dart' as p;

Mode? languageForPath(String? path) {
  if (path == null) return null;
  final name = p.basename(path).toLowerCase();
  final ext = p.extension(path).toLowerCase();

  switch (ext) {
    case '.dart':
      return dart;
    case '.js':
    case '.jsx':
    case '.mjs':
    case '.cjs':
      return javascript;
    case '.ts':
    case '.tsx':
      return typescript;
    case '.json':
      return json;
    case '.html':
    case '.htm':
    case '.xml':
    case '.svg':
    case '.xib':
    case '.plist':
      return xml;
    case '.css':
      return css;
    case '.scss':
    case '.sass':
      return scss;
    case '.py':
      return python;
    case '.go':
      return go;
    case '.rs':
      return rust;
    case '.java':
      return java;
    case '.kt':
    case '.kts':
      return kotlin;
    case '.swift':
      return swift;
    case '.rb':
      return ruby;
    case '.yaml':
    case '.yml':
      return yaml;
    case '.md':
    case '.mdx':
      return markdown;
    case '.sh':
    case '.bash':
    case '.zsh':
      return bash;
  }

  if (name == 'dockerfile' || name == 'makefile' || name == 'podfile') {
    return bash;
  }
  return null;
}

Map<String, TextStyle> syntaxTheme({required bool dark}) {
  return dark ? atomOneDarkTheme : atomOneLightTheme;
}
