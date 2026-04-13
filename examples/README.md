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

| File | What it shows |
| --- | --- |
| [logic/fibonacci.nerul](logic/fibonacci.nerul) | Recursive function, `if`, `return` |
| [logic/loops.nerul](logic/loops.nerul) | `for`, `while`, `break`, `continue` |
| [logic/variables.nerul](logic/variables.nerul) | `let`, compound assignments, scoping |

## What's not in Phase 2

- Arrays, maps, and string methods (Phase 3)
- `state` / save / load (Phase 4)
- Macros, i18n (Phase 4)
- Cross-file `@jump` (Phase 3 modules)
- Interpolation referencing state variables (requires Phase 4)
