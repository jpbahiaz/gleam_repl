# repl

A Gleam REPL, built entirely in Gleam. It treats the `gleam` CLI as a black box:
snippets are type-checked by `gleam build`, inferred types come from
`gleam export package-interface`, and compiled `.beam` files are hot-loaded into
the live Erlang node. Each expression is evaluated once — never replayed.

Erlang target only. JavaScript cannot hot-load BEAM.

## Run it here

```sh
gleam run
```

```
gleam repl  (Erlang target)
Type Gleam at the prompt. :help for commands, :quit to exit.

> let x = 5
5
> let y = x + 10
15
> fn double(n) { n * 2 }
> double(y)
30
> :type y
y : Int
```

## Use it in another project

```sh
gleam add --dev repl
gleam run -m repl
```

Run that from the **host project root** (the directory with `gleam.toml`). The
scratch module is written to `src/repl_session.gleam` in that project so you can
`import` your own modules. Add this to the host `.gitignore`:

```
src/repl_session.gleam
```

The host must compile to Erlang (`gleam build --target erlang`). JS-only
externals will fail that build.

## Commands

| Command | Action |
|---|---|
| `:quit`, `:q` | Exit |
| `:help`, `:h` | Show commands |
| `:type <name>` | Print the inferred type of a binding |
| `:reset` | Wipe bindings and the scratch module |
| Ctrl-D | Exit |

Unfinished input (`fn foo() {`) continues on a `... ` prompt. Several statements
pasted at once commit atomically — all land or none do.

## How it works

1. [glance](https://hex.pm/packages/glance) classifies the snippet (import, `let`,
   expression, `fn` / `type` / `const`).
2. The harness writes a candidate `src/repl_session.gleam`.
3. `gleam build` is the compile gate. Failure prints the compiler error and
   rolls the file back; state is unchanged.
4. `gleam export package-interface` supplies inferred types for later entries.
5. `code:load_binary` loads the new `.beam` into this node.
6. Value entries are called once via `erlang:apply`. The result is cached as a
   live BEAM term (so `Pid`s and other non-literals work).

`let` / expressions become `entry_N` wrappers and are never re-run.
Functions, types, and constants are stored under their real names (forced `pub`).
A `fn` that closes over a `let` binding is stored as a closure value instead.

## Limitations

- **BEAM keeps two module versions.** A process spawned from an earlier
  `repl_session` load is killed if that module is reloaded twice more. Put
  long-lived actors in a real `src/` module.
- Shadowed `entry_N` functions stay in the scratch file as dead code.
- `const` cannot close over REPL values (compile-time).
- No session history, git-worktree isolation, or syntax highlighting.

## Development

```sh
gleam test
gleam run
```
