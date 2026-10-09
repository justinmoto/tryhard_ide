# TryHard IDE (LocalForge)

An IDE for web developers with **local AI** that keeps working when the cloud and the internet are gone.

Hackathon theme: **Local AI**. All meaningful AI computation (completion, chat, search, translation, scanning) runs on the user's own device.

## Problem

Cloud AI coding tools stop working on flights, in poor-connectivity areas, and in restricted or air-gapped environments. They also send proprietary code to third-party servers, hit rate limits, and cost tokens. Developers who can't use cloud AI lose the productivity gains everyone else has.

## Solution

A Flutter desktop + mobile IDE that talks to a local LLM runtime (Ollama), a local embedding index, and AI tools focused on web development. Nothing leaves the machine, and everything works with Wi‑Fi off.

## Platforms

- **macOS** — primary demo target
- **iOS / Android** — mobile shell (chat + lighter tooling)
- **Web** — UI only; file I/O limited

## Prerequisites

- [Ollama](https://ollama.com) running locally (`http://127.0.0.1:11434`)
- Models:
  - `qwen2.5-coder:3b` — chat / fix / translate (primary on 8GB RAM)
  - `nomic-embed-text` — RAG embeddings
  - `qwen2.5-coder:7b` — optional, heavier

```bash
ollama pull qwen2.5-coder:3b
ollama pull nomic-embed-text
```

## Run

```bash
cd ~/Desktop/tryhard-ide

# Desktop (primary)
flutter run -d macos

# Mobile
flutter run -d ios
# or
flutter run -d android
```

## MVP features

### 0. Local Run (offline)
Run project scripts on-device with a log panel — no internet required if deps are already installed.

- [x] Detect `package.json` / `pubspec.yaml` / pytest targets
- [x] Run / Stop + log panel (`⌘R` run, `⌘J` toggle panel)
- [ ] Wire into Fix-Error Agent loop

### 1. Local AI Chat
Sidebar chat that knows the open file, the selection, and the project. Runs on a local coding model (e.g. `qwen2.5-coder` 3B/7B) through Ollama.

- [x] Ollama connection + status
- [x] Chat with open file / selection context
- [x] Prompt → auto-apply edit to open file/selection (saves to disk)
- [ ] Richer project-wide context

### 2. Offline Codebase Q&A (RAG)
Index the repo with a local embedding model (`nomic-embed-text`) into LanceDB / sqlite-vec. Ask questions like “Where is auth handled?” Answers cite files and lines.

- [ ] Repo indexing
- [ ] Vector store (LanceDB or sqlite-vec)
- [ ] Q&A with file:line citations

### 3. Fix-Error Agent
Run the build or tests (`npm run build`, Vitest, pytest), read the error output, propose a fix, show a diff to accept/reject, then re-run to confirm.

- [ ] Run build/tests from the IDE
- [ ] Propose fix + diff view
- [ ] Accept / reject + re-run loop

### 4. Cross-Language Code Translator
Translate code while preserving intended behavior, with a test-based verification loop (up to 3 retries). Show side-by-side diff and a badge like `12/12 tests match`.

| Translation | Notes |
|---|---|
| JavaScript → TypeScript | Infer types/interfaces, flag `any`, verify with `tsc --noEmit` |
| Python → JavaScript | Map idioms (comprehensions, dicts, context managers) |
| SQL dialects | MySQL / PostgreSQL / SQLite (sqlglot + LLM) — cuttable |

- [ ] JS ↔ Python path + test verification
- [ ] JS → TS + `tsc --noEmit`
- [ ] SQL conversion (lowest priority)

### 5. Offline Secret and Security Scanner
Run on save or as a pre-commit hook. Small local model decides real secret vs mock data. Suggest moving secrets into `.env`.

- [ ] Pattern / heuristic scan
- [ ] Local model triage
- [ ] `.env` suggestions

### 6. Local AI Transparency Panel
“100% on-device” badge, live resource stats, model switcher with a lighter fallback for weak laptops.

- [x] On-device badge + Ollama online/offline
- [x] Model switcher
- [ ] Live RAM / CPU / GPU / tokens-per-second

## Architecture

```
┌────────────────────────────────────────────────┐
│  UI: Flutter (macOS + iOS/Android)             │
└───────────────────────┬────────────────────────┘
                        │ HTTP localhost
┌───────────────────────▼────────────────────────┐
│  Local inference: Ollama / llama.cpp           │
│  Models: qwen2.5-coder 3B/7B, nomic-embed-text │
└───────────────────────┬────────────────────────┘
                        │
┌───────────────────────▼────────────────────────┐
│  Local storage and tools                       │
│  LanceDB / sqlite-vec, git, tsc, sqlglot,      │
│  test runners (Vitest, pytest)                 │
└────────────────────────────────────────────────┘
```

## Tech stack

| Layer | Choice |
|---|---|
| Shell / UI | Flutter (Dart) — desktop + mobile |
| AI runtime | Ollama (llama.cpp) |
| Vector store | LanceDB or sqlite-vec |
| Translation helpers | TypeScript compiler API, sqlglot |
| Testing | Vitest/Jest, pytest |

## 24-hour build plan

| Hours | Task |
|---|---|
| 0–4 | App shell: editor, file open, Ollama connection |
| 4–7 | Chat sidebar with file and selection context |
| 7–12 | Repo indexing and codebase Q&A (RAG) |
| 12–16 | Fix-error agent with diff view |
| 16–21 | Cross-language translator + test verification loop |
| 21–23 | Secret scanner and transparency panel extras |
| 23–24 | Demo repo, rehearsal, model pre-download check |

### Cut order if time runs short

1. Secret scanner  
2. Transparency panel extras (live RAM/TPS)  
3. SQL conversion  

**Keep:** translator JS ↔ Python path, fix-error agent, chat, RAG.

## Demo script

1. Turn off Wi‑Fi on stage.
2. Open a broken Next.js project and ask a codebase question.
3. Click the fix-error button and accept the diff.
4. Translate a Python function to JavaScript and show the “tests match” badge.
5. Show the on-device resource panel.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Slow models on weak laptops | Use 3B fallback; test early |
| Translation accuracy | One function/file at a time; deterministic tools where possible |
| Model downloads | Pre-download before the event |

## Current repo layout

```
lib/
  main.dart
  screens/ide_shell.dart
  services/ollama_service.dart
  widgets/chat_sidebar.dart
  widgets/transparency_panel.dart
```
