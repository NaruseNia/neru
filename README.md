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
# Logic-only script
cat <<'EOF' > hello.nerul
fn fib(n) {
  if n <= 1 { return n }
  return fib(n - 1) + fib(n - 2)
}
let result = fib(10)
EOF

neru run hello.nerul
# => 55

# Scenario script — use --mock to drive the built-in auto-responder
cat <<'EOF' > hello.neru
@speaker Alice
Hello, traveler!
@wait 500
Where are you heading today?
EOF

neru run --mock hello.neru
# => [speaker] Alice
#    [text] Alice: Hello, traveler!
#    [wait] 500ms
#    [text] Alice: Where are you heading today?

# Compile to bytecode
neru compile hello.nerul
# => hello.neruc
```

More runnable examples live under [`examples/`](examples/README.md).

## Features

- **Scenario Layer** (`.neru`) — Text lines, `@speaker`/`@wait`/`@clear`, `@bg`/`@show`/`@bgm`/`@se`/`@transition` with `--key=value` options, `#label` + `@goto`, `#choice` with conditional entries, `@if`/`@elif`/`@else`/`@end`, `@call`/`@eval`, and `{expression}` interpolation
- **Logic Layer** (`.nerul`) — Expressions, `let`, `fn`, `if`/`else`, `for`/`while`, `break`/`continue`, recursive calls, compound assignments
- **Bytecode VM** — Stack-based virtual machine implemented in Zig. Emits engine-independent events (text, choices, effects) instead of executing them directly
- **Mock Engine** — `neru run --mock` drives a script end-to-end without an engine, auto-acking events and printing them to stdout
- **Cross-platform** — Linux, macOS, Windows binaries are shipped from CI

### What's still coming

- Arrays, maps, closures, modules (Phase 3)
- State management, save/load, macros, i18n (Phase 4)
- LSP, debugger, formatter (Phase 5)

## Examples

### Scenario (`.neru`)

```
@bg forest.png --fade=slow
@bgm theme.ogg --volume=0.8
@show taro --pos=center

@speaker Taro
It's quiet in the forest today.
@wait 500

#choice
  - "Call out" -> call
  - "Stay silent" -> silent
  - "Secret option" -> secret @if 1 == 1

#call
@speaker Taro
Hello!
@goto done

#silent
@speaker Narrator
(Taro keeps walking.)
@goto done

#secret
@speaker Narrator
You unlocked the hidden branch.
@goto done

#done
@bgm_stop
```

### Logic (`.nerul`)

```
fn factorial(n) {
  if n <= 1 { return 1 }
  return n * factorial(n - 1)
}

let x = factorial(5)  // 120

for i in 0..10 {
  // loop body
}

while x > 0 {
  x -= 1
}
```

## Build from Source

Requires [Zig](https://ziglang.org/) 0.15.2+.

```sh
zig build              # Build
zig build run          # Build and run CLI
zig build test         # Run all tests
```

## Use as a Zig library

### Add the dependency

Fetch the package into your project's `build.zig.zon`:

```sh
zig fetch --save=neru git+https://github.com/NaruseNia/neru#v0.2.0
```

Then wire the module into `build.zig`:

```zig
const neru_dep = b.dependency("neru", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("neru", neru_dep.module("neru"));
```

### Usage

```zig
const neru = @import("neru");

// Compile
var diags = neru.compiler.DiagnosticList.init(allocator);
var nodes = neru.compiler.NodeStore.init(allocator);
var lexer = neru.compiler.Lexer.init(source, &diags, .scenario); // or .logic
var parser = neru.compiler.Parser.init(allocator, &lexer, &nodes, &diags);
const root = try parser.parseProgram();

var compiler = neru.compiler.Compiler.init(allocator, &nodes, &diags);
const module = try compiler.compile(root);

// Run in event-driven mode (scenario-friendly)
var vm = neru.vm.VM.init(allocator);
defer vm.deinit();
vm.load(module);
while (try vm.runUntilEvent()) |event| {
    // handle event and send a Response back
    vm.resumeWith(.{ .none = {} });
}
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
| 2. Scenario Layer | Done | Text, speakers, media directives, flow control, conditionals, events |
| 3. Logic Layer | Planned | Arrays, maps, closures, modules |
| 4. Integration | Planned | State management, save/load, macros, i18n |
| 5. Developer Tools | Planned | LSP, debugger, formatter |

## License

[MIT](LICENSE)
