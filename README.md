# neru

[![CI](https://github.com/NaruseNia/neru/actions/workflows/ci.yml/badge.svg)](https://github.com/NaruseNia/neru/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/NaruseNia/neru)](https://github.com/NaruseNia/neru/releases/latest)

A scripting language for the visual novel engine [nerune-engine](https://github.com/NaruseNia/nerune-engine).

Designed with a two-layer architecture so both scenario writers and programmers can work comfortably.

[日本語版 README](README_ja.md)

> [!WARNING]
> This project is under active development. The language specification and API are subject to breaking changes without notice. **Do not use in production.**

## Quick Start

Download the latest binary from [Releases](https://github.com/NaruseNia/neru/releases/latest), then:

```sh
# Write a script
cat <<'EOF' > hello.nerul
fn fib(n) {
  if n <= 1 { return n }
  return fib(n - 1) + fib(n - 2)
}
let result = fib(10)
EOF

# Run it
neru run hello.nerul
# => 55

# Or compile to bytecode
neru compile hello.nerul
# => hello.neruc
```

## Features

- **Scenario Layer** (`.neru`) — Markdown-extended syntax. Plain text becomes dialogue as-is *(Phase 2)*
- **Logic Layer** (`.nerul`) — Custom scripting language for game logic
- **Bytecode VM** — Stack-based virtual machine implemented in Zig
- **Loosely Coupled** — Outputs engine-independent intermediate representation
- **Internationalization (i18n)** — Multi-language support at the language level *(Phase 4)*
- **Cross-platform** — Linux, macOS, Windows binaries available

## Examples

### Logic (.nerul) — Available Now

```
let x = 42
let name = "neru"

fn factorial(n) {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

let result = factorial(5)  // 120

for i in 0..10 {
  // loop body
}

while x > 0 {
  x -= 1
}
```

### Scenario (.neru) — Coming in Phase 2

```
@speaker Taro
@bg schoolyard.png --fade 500

"Hello, my name is {state.player_name}"
"Nice weather today, isn't it?"

#choice
  - "Yeah, it is" -> good_route
  - "Is it though?" -> bad_route
```

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15.2+.

```sh
zig build              # Build
zig build run          # Build and run CLI
zig build test         # Run all tests (104 tests)
```

### Zig Library

neru can be used as a Zig library:

```zig
const neru = @import("neru");

var vm = neru.vm.VM.init(allocator);
var lexer = neru.compiler.Lexer.init(source, &diags);
var parser = neru.compiler.Parser.init(allocator, &lexer, &nodes, &diags);
// ...
```

## Documentation

- [API Reference](docs/api-reference.md)
- [Language Specification](docs/specification/language-spec.md)
- [Architecture](docs/specification/architecture.md)
- [Implementation Plan](docs/specification/implementation-plan.md)
- [EBNF Grammar](docs/specification/grammar.ebnf)

## Roadmap

| Phase | Status | Description |
|---|---|---|
| 1. Core Foundation | Done | Lexer, Parser, Codegen, VM, CLI |
| 2. Scenario Layer | Next | Text display, choices, directives, events |
| 3. Logic Layer | Planned | Arrays, maps, closures, modules |
| 4. Integration | Planned | State management, save/load, macros, i18n |
| 5. Developer Tools | Planned | LSP, debugger, formatter |

## License

[MIT](LICENSE)
