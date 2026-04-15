# neru examples

Runnable sample programs for both the scenario layer (`.neru`) and the logic
layer (`.nerul`). Each script can be executed directly with:

```sh
# From the project root, after `zig build`:
./zig-out/bin/neru run --mock examples/scenario/hello.neru
./zig-out/bin/neru run examples/logic/fibonacci.nerul
```

The `--mock` flag drives scenario scripts through a built-in mock engine
that auto-responds to every event (choice picks the first visible option,
text/wait are acknowledged immediately) and prints each event to stdout.

## Scenario (.neru)

| File | What it shows |
| --- | --- |
| [scenario/hello.neru](scenario/hello.neru) | Basic dialog, `@speaker`, `@wait`, `@clear` |
| [scenario/effects.neru](scenario/effects.neru) | Media directives: `@bg`, `@show`, `@bgm`, `@se`, `@transition` |
| [scenario/branching.neru](scenario/branching.neru) | Labels, `@goto`, `#choice` branching |
| [scenario/conditional.neru](scenario/conditional.neru) | `@if`/`@elif`/`@else`/`@end` and conditional choices |
| [scenario/showcase.neru](scenario/showcase.neru) | Full tour combining every Phase 2 feature |

## Logic (.nerul)

### Basics

| File | What it shows |
| --- | --- |
| [logic/fibonacci.nerul](logic/fibonacci.nerul) | Recursive function, `if`, `return` |
| [logic/loops.nerul](logic/loops.nerul) | `for`, `while`, `break`, `continue` |
| [logic/variables.nerul](logic/variables.nerul) | `let`, compound assignments, scoping |

### Phase 3 Features

| File | What it shows |
| --- | --- |
| [logic/arrays_and_maps.nerul](logic/arrays_and_maps.nerul) | Array/map creation, methods, iteration, nesting |
| [logic/closures.nerul](logic/closures.nerul) | First-class functions, closures, transform/filter patterns |
| [logic/strings.nerul](logic/strings.nerul) | String methods, concatenation, comparison, split |
| [logic/builtins.nerul](logic/builtins.nerul) | `math.*` and `debug.*` built-in modules |
| [logic/modules/main.nerul](logic/modules/main.nerul) | `@import` module system with [math_lib.nerul](logic/modules/math_lib.nerul) |
| [logic/game_rpg.nerul](logic/game_rpg.nerul) | Mini RPG: combat, inventory, maps, closures combined |

## What's not yet available

- `state` / save / load (Phase 4)
- Macros, i18n (Phase 4)
- Cross-file `@jump` execution (Phase 3.6 parsed but runtime halts)
