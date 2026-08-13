import gleam/int
import gleam/list
import gleam/option.{None}
import gleam/package_interface.{type Type}
import gleam/string
import repl/state.{type ImportSpec, ImportSpec}

pub fn render(
  type_: Type,
  scratch_module: String,
  imports: List(ImportSpec),
) -> #(String, List(ImportSpec)) {
  let vars = assign_vars(collect_vars(type_, []))
  render_with(type_, scratch_module, imports, vars)
}

fn render_with(
  type_: Type,
  scratch_module: String,
  imports: List(ImportSpec),
  vars: List(#(Int, String)),
) -> #(String, List(ImportSpec)) {
  case type_ {
    package_interface.Tuple(elements) -> {
      let #(imports, parts) =
        render_many(elements, scratch_module, imports, vars)
      #("#(" <> string.join(parts, ", ") <> ")", imports)
    }
    package_interface.Fn(parameters, return) -> {
      let #(imports, params) =
        render_many(parameters, scratch_module, imports, vars)
      let #(ret, imports) = render_with(return, scratch_module, imports, vars)
      #("fn(" <> string.join(params, ", ") <> ") -> " <> ret, imports)
    }
    package_interface.Variable(id) ->
      case list.key_find(vars, id) {
        Ok(name) -> #(name, [])
        Error(_) -> #("a", [])
      }
    package_interface.Named(name:, package: _, module:, parameters:) -> {
      let #(extra, params) =
        render_many(parameters, scratch_module, imports, vars)
      let #(qualified, extra2) =
        qualify_name(name, module, scratch_module, imports)
      let text = case params {
        [] -> qualified
        _ -> qualified <> "(" <> string.join(params, ", ") <> ")"
      }
      #(text, list.append(extra, extra2))
    }
  }
}

fn render_many(
  types: List(Type),
  scratch_module: String,
  imports: List(ImportSpec),
  vars: List(#(Int, String)),
) -> #(List(ImportSpec), List(String)) {
  list.map_fold(types, [], fn(extra, type_) {
    let #(text, more) = render_with(type_, scratch_module, imports, vars)
    #(list.append(extra, more), text)
  })
}

fn qualify_name(
  name: String,
  module: String,
  scratch_module: String,
  imports: List(ImportSpec),
) -> #(String, List(ImportSpec)) {
  case module == "gleam" || module == scratch_module || module == "" {
    True -> #(name, [])
    False ->
      case find_import(imports, module) {
        Ok(spec) -> #(state.import_alias(spec) <> "." <> name, [])
        Error(_) -> {
          let spec = ImportSpec(module:, alias: None, types: [], values: [])
          #(state.last_segment(module) <> "." <> name, [spec])
        }
      }
  }
}

fn find_import(
  imports: List(ImportSpec),
  module: String,
) -> Result(ImportSpec, Nil) {
  list.find(imports, fn(spec) { spec.module == module })
}

fn collect_vars(type_: Type, acc: List(Int)) -> List(Int) {
  case type_ {
    package_interface.Variable(id) ->
      case list.contains(acc, id) {
        True -> acc
        False -> list.append(acc, [id])
      }
    package_interface.Tuple(elements) ->
      list.fold(elements, acc, fn(acc, t) { collect_vars(t, acc) })
    package_interface.Fn(parameters, return) ->
      collect_vars(
        return,
        list.fold(parameters, acc, fn(acc, t) { collect_vars(t, acc) }),
      )
    package_interface.Named(parameters:, ..) ->
      list.fold(parameters, acc, fn(acc, t) { collect_vars(t, acc) })
  }
}

fn assign_vars(ids: List(Int)) -> List(#(Int, String)) {
  list.index_map(ids, fn(id, index) { #(id, var_name(index)) })
}

fn var_name(index: Int) -> String {
  let letter = case index % 26 {
    0 -> "a"
    1 -> "b"
    2 -> "c"
    3 -> "d"
    4 -> "e"
    5 -> "f"
    6 -> "g"
    7 -> "h"
    8 -> "i"
    9 -> "j"
    10 -> "k"
    11 -> "l"
    12 -> "m"
    13 -> "n"
    14 -> "o"
    15 -> "p"
    16 -> "q"
    17 -> "r"
    18 -> "s"
    19 -> "t"
    20 -> "u"
    21 -> "v"
    22 -> "w"
    23 -> "x"
    24 -> "y"
    _ -> "z"
  }
  case index / 26 {
    0 -> letter
    n -> letter <> int.to_string(n)
  }
}

pub fn render_function(
  parameters: List(package_interface.Parameter),
  return: Type,
  scratch_module: String,
  imports: List(ImportSpec),
) -> #(String, List(ImportSpec)) {
  render(
    package_interface.Fn(list.map(parameters, fn(p) { p.type_ }), return),
    scratch_module,
    imports,
  )
}
