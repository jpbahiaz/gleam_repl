import gleam/dict
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import repl/classify.{type Item, DefinitionItem, FnDef, ImportItem, ValueItem}
import repl/state.{
  type BindingKind, type HarnessState, type ImportSpec, type Unqualified,
  Definition, ImportSpec, Value,
}

pub type Call {
  ApplyFn(
    entry_fn: String,
    arg_fns: List(String),
    store_as: String,
    bind_names: List(String),
    print: Bool,
  )
  Project(
    from: String,
    index: Int,
    store_as: String,
    bind_names: List(String),
    print: Bool,
  )
}

pub type Plan {
  Plan(
    source: String,
    body: String,
    imports: List(ImportSpec),
    calls: List(Call),
    dirty: List(#(Int, Int)),
  )
}

pub fn generate(state: HarnessState, items: List(Item)) -> #(Plan, Int) {
  let #(body, calls, next_id, dirty_texts) =
    list.fold(items, #(state.body, [], state.next_entry_id, []), fn(acc, item) {
      let #(body, calls, next_id, dirty_texts) = acc
      case item {
        ImportItem(_, _) -> #(body, calls, next_id, dirty_texts)
        DefinitionItem(name:, kind:, source:, captured_values:) ->
          case kind, captured_values {
            FnDef, [_, ..] as captured -> {
              let #(fn_src, calls2, next_id) =
                closure_value(state, name, source, captured, next_id)
              #(
                append_block(body, fn_src),
                list.append(calls, calls2),
                next_id,
                list.append(dirty_texts, [fn_src]),
              )
            }
            _, _ -> {
              let block = def_block(name, source)
              #(
                replace_or_append_def(body, name, source),
                calls,
                next_id,
                list.append(dirty_texts, [block]),
              )
            }
          }
        ValueItem(
          names:,
          rhs:,
          pattern:,
          simple:,
          is_assert:,
          params:,
          source: _,
        ) -> {
          let #(fn_src, calls2, next_id) =
            value_fns(
              state,
              names,
              rhs,
              pattern,
              simple,
              is_assert,
              params,
              next_id,
            )
          #(
            append_block(body, fn_src),
            list.append(calls, calls2),
            next_id,
            list.append(dirty_texts, [fn_src]),
          )
        }
      }
    })
  let imports =
    list.fold(items, state.imports, fn(imports, item) {
      case item {
        ImportItem(spec:, source: _) -> merge_import(imports, spec)
        _ -> imports
      }
    })
  let source = render(imports, body)
  let dirty_texts = case import_block(state.imports) == import_block(imports) {
    True -> dirty_texts
    False ->
      case import_block(imports) {
        "" -> dirty_texts
        block -> [block, ..dirty_texts]
      }
  }
  let dirty = line_ranges(source, dirty_texts)
  #(Plan(source:, body:, imports:, calls:, dirty:), next_id)
}

pub fn render(imports: List(ImportSpec), body: String) -> String {
  let import_block = import_block(imports)
  case import_block, string.trim(body) {
    "", "" -> state.empty_scratch
    "", _ -> state.empty_scratch <> "\n" <> string.trim(body) <> "\n"
    _, "" -> state.empty_scratch <> "\n" <> import_block <> "\n"
    _, _ ->
      state.empty_scratch
      <> "\n"
      <> import_block
      <> "\n\n"
      <> string.trim(body)
      <> "\n"
  }
}

fn import_block(imports: List(ImportSpec)) -> String {
  imports
  |> list.map(render_import)
  |> string.join("\n")
}

fn line_ranges(source: String, needles: List(String)) -> List(#(Int, Int)) {
  list.filter_map(needles, fn(needle) { find_range(source, needle) })
}

fn find_range(source: String, needle: String) -> Result(#(Int, Int), Nil) {
  case needle {
    "" -> Error(Nil)
    _ ->
      case string.split_once(source, needle) {
        Error(_) -> Error(Nil)
        Ok(#(before, _)) -> {
          let start = newline_count(before) + 1
          Ok(#(start, start + newline_count(needle)))
        }
      }
  }
}

fn newline_count(src: String) -> Int {
  case string.split(src, "\n") {
    [] -> 0
    parts -> list.length(parts) - 1
  }
}

pub fn render_import(spec: ImportSpec) -> String {
  let base = "import " <> spec.module
  let base = case spec.alias {
    Some(alias) -> base <> " as " <> alias
    None -> base
  }
  let types = list.map(spec.types, render_unqualified_type)
  let values = list.map(spec.values, render_unqualified)
  let unqualified = list.append(types, values)
  case unqualified {
    [] -> base
    _ -> base <> ".{" <> string.join(unqualified, ", ") <> "}"
  }
}

fn render_unqualified(item: Unqualified) -> String {
  case item.alias {
    Some(alias) -> item.name <> " as " <> alias
    None -> item.name
  }
}

fn render_unqualified_type(item: Unqualified) -> String {
  "type " <> render_unqualified(item)
}

fn merge_import(
  imports: List(ImportSpec),
  spec: ImportSpec,
) -> List(ImportSpec) {
  let #(same, rest) =
    list.partition(imports, fn(existing) {
      existing.module == spec.module && existing.alias == spec.alias
    })
  case same {
    [] -> list.append(imports, [spec])
    [first, ..] -> {
      let merged =
        ImportSpec(
          module: spec.module,
          alias: spec.alias,
          types: merge_unqualified(first.types, spec.types),
          values: merge_unqualified(first.values, spec.values),
        )
      list.append(rest, [merged])
    }
  }
}

fn merge_unqualified(
  left: List(Unqualified),
  right: List(Unqualified),
) -> List(Unqualified) {
  list.fold(right, left, fn(acc, item) {
    case list.find(acc, fn(existing) { existing.name == item.name }) {
      Ok(_) -> acc
      Error(_) -> list.append(acc, [item])
    }
  })
}

fn value_fns(
  state: HarnessState,
  names: List(String),
  rhs: String,
  pattern: String,
  simple: Bool,
  is_assert: Bool,
  params: List(String),
  next_id: Int,
) -> #(String, List(Call), Int) {
  let entry = state.entry_name(next_id)
  let header = fn_header(entry, params, state)
  let keyword = case is_assert {
    True -> "let assert "
    False -> "let "
  }
  let body = case simple, names, is_assert {
    True, [_], False -> rhs
    _, [], _ -> rhs
    True, [name], True -> keyword <> name <> " = " <> rhs <> "\n  " <> name
    _, [name], _ -> keyword <> pattern <> " = " <> rhs <> "\n  " <> name
    _, names, _ ->
      keyword
      <> pattern
      <> " = "
      <> rhs
      <> "\n  #("
      <> string.join(names, ", ")
      <> ")"
  }
  let main_fn = header <> " {\n  " <> body <> "\n}"
  let apply =
    ApplyFn(
      entry_fn: entry,
      arg_fns: resolve_args(state, params),
      store_as: entry,
      bind_names: case names {
        [name] -> [name]
        [] -> []
        _ -> []
      },
      print: case names {
        [] -> True
        [_] -> True
        _ -> False
      },
    )
  case names {
    [] | [_] -> #(main_fn, [apply], next_id + 1)
    names -> {
      let projections =
        list.index_map(names, fn(name, index) {
          Project(
            from: entry,
            index: index + 1,
            store_as: entry <> "__" <> name,
            bind_names: [name],
            print: True,
          )
        })
      #(main_fn, [apply, ..projections], next_id + 1)
    }
  }
}

fn closure_value(
  state: HarnessState,
  name: String,
  source: String,
  captured: List(String),
  next_id: Int,
) -> #(String, List(Call), Int) {
  let entry = state.entry_name(next_id)
  let header = fn_header(entry, captured, state)
  let src = header <> " {\n  " <> to_anonymous_fn(source) <> "\n}"
  let call =
    ApplyFn(
      entry_fn: entry,
      arg_fns: resolve_args(state, captured),
      store_as: entry,
      bind_names: [name],
      print: False,
    )
  #(src, [call], next_id + 1)
}

fn to_anonymous_fn(src: String) -> String {
  src
  |> string.trim
  |> drop_keyword("pub")
  |> string.trim
  |> drop_fn_name
}

fn drop_keyword(src: String, keyword: String) -> String {
  case string.starts_with(src, keyword) {
    False -> src
    True -> {
      let rest = string.drop_start(src, string.length(keyword))
      case rest {
        " " <> rest | "\n" <> rest | "\t" <> rest -> rest
        _ -> src
      }
    }
  }
}

fn drop_fn_name(src: String) -> String {
  case src {
    "fn" <> rest -> {
      let rest = string.trim_start(rest)
      "fn" <> drop_ident(rest)
    }
    _ -> src
  }
}

fn drop_ident(src: String) -> String {
  case string.pop_grapheme(src) {
    Ok(#(g, rest)) ->
      case is_ident_char(g) {
        True -> drop_ident(rest)
        False -> src
      }
    Error(_) -> src
  }
}

fn is_ident_char(g: String) -> Bool {
  case g {
    "_"
    | "0"
    | "1"
    | "2"
    | "3"
    | "4"
    | "5"
    | "6"
    | "7"
    | "8"
    | "9"
    | "a"
    | "b"
    | "c"
    | "d"
    | "e"
    | "f"
    | "g"
    | "h"
    | "i"
    | "j"
    | "k"
    | "l"
    | "m"
    | "n"
    | "o"
    | "p"
    | "q"
    | "r"
    | "s"
    | "t"
    | "u"
    | "v"
    | "w"
    | "x"
    | "y"
    | "z"
    | "A"
    | "B"
    | "C"
    | "D"
    | "E"
    | "F"
    | "G"
    | "H"
    | "I"
    | "J"
    | "K"
    | "L"
    | "M"
    | "N"
    | "O"
    | "P"
    | "Q"
    | "R"
    | "S"
    | "T"
    | "U"
    | "V"
    | "W"
    | "X"
    | "Y"
    | "Z" -> True
    _ -> False
  }
}

fn fn_header(
  name: String,
  params: List(String),
  state: HarnessState,
) -> String {
  let args =
    params
    |> list.map(fn(param) {
      case dict_type(state, param) {
        "" -> param
        gleam_type -> param <> ": " <> gleam_type
      }
    })
    |> string.join(", ")
  "pub fn " <> name <> "(" <> args <> ")"
}

fn dict_type(state: HarnessState, name: String) -> String {
  case dict.get(state.symbol_table, name) {
    Ok(Value(_, gleam_type)) -> gleam_type
    Ok(Definition(_, gleam_type)) -> gleam_type
    Error(_) -> ""
  }
}

fn resolve_args(state: HarnessState, params: List(String)) -> List(String) {
  list.map(params, fn(name) {
    case dict.get(state.symbol_table, name) {
      Ok(Value(entry_fn, _)) -> entry_fn
      Ok(Definition(real_name, _)) -> real_name
      Error(_) -> name
    }
  })
}

fn replace_or_append_def(body: String, name: String, source: String) -> String {
  let block = def_block(name, source)
  let start = "// @repl-def " <> name
  let end = "// @repl-end " <> name
  case string.split_once(body, start) {
    Error(_) -> append_block(body, block)
    Ok(#(before, rest)) ->
      case string.split_once(rest, end) {
        Ok(#(_old, after)) ->
          string.trim_end(before) <> "\n\n" <> block <> after
        Error(_) -> append_block(body, block)
      }
  }
}

fn def_block(name: String, source: String) -> String {
  "// @repl-def "
  <> name
  <> "\n"
  <> string.trim(source)
  <> "\n// @repl-end "
  <> name
}

fn append_block(body: String, block: String) -> String {
  case string.trim(body) {
    "" -> block
    trimmed -> trimmed <> "\n\n" <> block
  }
}

pub fn binding_updates(
  items: List(Item),
  calls: List(Call),
) -> List(#(String, BindingKind)) {
  let from_defs =
    list.filter_map(items, fn(item) {
      case item {
        DefinitionItem(name:, captured_values: [], ..) ->
          Ok(#(name, Definition(name, "")))
        _ -> Error(Nil)
      }
    })
  let from_calls =
    list.flat_map(calls, fn(call) {
      case call {
        ApplyFn(store_as:, bind_names:, ..) ->
          list.map(bind_names, fn(name) { #(name, Value(store_as, "")) })
        Project(store_as:, bind_names:, ..) ->
          list.map(bind_names, fn(name) { #(name, Value(store_as, "")) })
      }
    })
  list.append(from_defs, from_calls)
}

pub fn polish_compiler_error(message: String, scratch_path: String) -> String {
  message
  |> rewrite_scratch_paths
  |> string.replace(scratch_path, "<repl>")
  |> string.replace("dev/repl.gleam", "<repl>")
}

fn rewrite_scratch_paths(text: String) -> String {
  case string.split_once(text, state.scratch_prefix) {
    Error(_) -> text
    Ok(#(before, after)) ->
      case consume_scratch_tail(after) {
        Ok(rest) -> {
          let #(kept, _) = split_off_path(before)
          kept <> "<repl>" <> rewrite_scratch_paths(rest)
        }
        Error(_) ->
          before <> state.scratch_prefix <> rewrite_scratch_paths(after)
      }
  }
}

fn consume_scratch_tail(after: String) -> Result(String, Nil) {
  case string.split_once(after, ".gleam") {
    Error(_) -> Error(Nil)
    Ok(#(mid, rest)) ->
      case string.contains(mid, "/") || string.contains(mid, "\\") {
        True -> Error(Nil)
        False -> Ok(rest)
      }
  }
}

fn split_off_path(before: String) -> #(String, String) {
  take_trailing_path(list.reverse(string.to_graphemes(before)), [])
}

fn take_trailing_path(
  reversed: List(String),
  path: List(String),
) -> #(String, String) {
  case reversed {
    [] -> #("", string.concat(path))
    [g, ..rest] ->
      case is_path_char(g) {
        True -> take_trailing_path(rest, [g, ..path])
        False -> #(
          string.concat(list.reverse([g, ..rest])),
          string.concat(path),
        )
      }
  }
}

fn is_path_char(g: String) -> Bool {
  case g {
    "/" | "\\" | "." | "-" | "_" -> True
    _ -> is_ident_char(g)
  }
}
