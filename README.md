# neru

A scripting language for the visual novel engine [nerune-engine](https://github.com/NaruseNia/nerune-engine).

Designed with a two-layer architecture so both scenario writers and programmers can work comfortably.

[日本語版 README](README_ja.md)

> **Warning**
> This project is under active development. The language specification and API are subject to breaking changes without notice. **Do not use in production.**

## Features

- **Scenario Layer** (`.neru`) — Markdown-extended syntax. Plain text becomes dialogue as-is
- **Logic Layer** (`.nerul`) — Custom scripting language for game logic
- **Bytecode VM** — High-performance virtual machine implemented in Zig
- **Loosely Coupled** — Outputs engine-independent intermediate representation
- **Internationalization (i18n)** — Multi-language support at the language level

## Examples

### Scenario (.neru)

```
@speaker Taro
@bg schoolyard.png --fade 500

"Hello, my name is {state.player_name}"
"Nice weather today, isn't it?"

#choice
  - "Yeah, it is" -> good_route
  - "Is it though?" -> bad_route

# good_route
@eval state.affinity.taro += 5
"Thanks!"

# bad_route
"I see..."
```

### Logic (.nerul)

```
fn give_item(item) {
  state.inventory.push(item)
  debug.log("Added: " + item)
}

fn check_affinity(char) {
  if state.affinity[char] >= 50 {
    return true
  }
  return false
}
```

## Documentation

- [Requirements](docs/specification/requirements.md)
- [Language Specification](docs/specification/language-spec.md)
- [Architecture](docs/specification/architecture.md)
- [Implementation Plan](docs/specification/implementation-plan.md)
- [EBNF Grammar](docs/specification/grammar.ebnf)

## Build

```sh
zig build
```

## License

[MIT](LICENSE)
