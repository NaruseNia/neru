# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

neru is a scripting language for the visual novel engine **nerune-engine** (wgpu-based). It uses a two-layer architecture:

- **Scenario layer** (`.neru`) — Markdown-extended syntax for writers. Plain text becomes dialogue, `@` directives for commands, `{var}` for interpolation.
- **Logic layer** (`.nerul`) — Custom scripting language for programmers. Dynamic typing, functions, loops, arrays/maps.

Implementation language is **Zig** (minimum 0.15.2). The compiler pipeline is: Lexer → Parser → Bytecode Generator → VM execution. An interpreter mode (AST walker) is also planned for development use.

## Workflow Rules

- **Commit per task**: Always create a separate commit for each logical task. Do not batch unrelated changes into a single commit.
- **Discuss before assuming**: When anything is unclear or ambiguous, use `AskUserQuestion` to discuss with the user before proceeding. Do not guess or make assumptions on design decisions.
- **Branch and PR flow**: When the task warrants it, create a feature branch before starting work. Once complete, open a PR and merge. Do not push directly to main for non-trivial changes.
- **Update docs after work**: After completing a task, update relevant documents under `docs/` as needed. In particular, keep the checklist in `docs/specification/implementation-plan.md` up to date to reflect the current implementation status.

## Build & Test Commands

```sh
zig build              # Build the project
zig build run          # Build and run the CLI
zig build test         # Run all tests (module + executable)
```

## Architecture

The system has three main layers:

1. **Compiler** (`src/compiler/`) — Lexer tokenizes `.neru`/`.nerul` files with mode switching based on file extension. Parser produces AST. Codegen emits bytecode (`.neruc` format).
2. **VM** (`src/vm/`) — Stack-based bytecode VM. Emits events (text display, choices, effects) to an event queue rather than executing them directly. The engine consumes these events.
3. **Runtime** (`src/runtime/`) — Global `state` object management, built-in functions, event system for engine communication.

The VM is **loosely coupled** with nerune-engine: it outputs engine-independent events, and the engine responds with user actions (choice selected, text acknowledged). This is the core interface:
- `run_until_event()` — execute bytecode until an event is emitted
- `resume(response)` — continue execution with engine's response

## Specification Documents

All specs are in `docs/specification/` and written in Japanese:
- `requirements.md` — Requirements and design decisions
- `language-spec.md` — Complete language reference
- `architecture.md` — System architecture, bytecode format, VM design, engine interface
- `implementation-plan.md` — 5-phase roadmap with task checklists
- `grammar.ebnf` — Formal grammar (ISO/IEC 14977 EBNF)

## Language Design Notes

- The lexer has two modes: **scenario mode** (default for `.neru`) and **logic mode** (default for `.nerul`). Within `.neru` files, `@eval`/`@call` arguments temporarily switch to logic mode.
- `state` is a global built-in object with auto-initializing nested maps. It is automatically serialized on save and restored on load.
- Macros (`@macro`) expand at compile time in the scenario layer.
- i18n is supported from initial release via text keys and locale files.

## Implementation Phases

1. Lexer, Parser, Bytecode Compiler, basic VM
2. Scenario layer (text, choices, directives, events)
3. Logic layer (variables, functions, loops, data structures)
4. Integration (state, save/load, macros, i18n)
5. Tools (CLI, LSP, debugger)
