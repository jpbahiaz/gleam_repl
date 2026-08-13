import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/package_interface.{type Package}
import gleam/result
import gleam/string
import repl/classify.{
  type Env, type Item, ClassifyEmpty, ClassifyError, ClassifyIncomplete,
  DefinitionItem, ImportItem, Items,
}
import repl/codegen.{type Call, type Plan}
import repl/compile
import repl/hotload
import repl/state.{
  type BindingKind, type EvalError, type HarnessState, type ImportSpec,
  type Outcome, type Project, CompileError, Defined, Definition, HarnessState,
  Imported, Incomplete, NoOutcome, ParseError, Printed, RuntimeError, Value,
}
import repl/types

pub fn eval_snippet(
  project: Project,
  state: HarnessState,
  src: String,
) -> #(HarnessState, Result(List(Outcome), EvalError)) {
  let env = env_of(state)
  case classify.classify(src, env) {
    ClassifyEmpty -> #(state, Ok([NoOutcome]))
    ClassifyIncomplete -> #(state, Error(Incomplete))
    ClassifyError(message) -> #(state, Error(ParseError(message)))
    Items(items) -> run_items(project, state, items)
  }
}

fn run_items(
  project: Project,
  state: HarnessState,
  items: List(Item),
) -> #(HarnessState, Result(List(Outcome), EvalError)) {
  let previous = Ok(state.module_source)
  let #(plan, next_id) = codegen.generate(state, items)
  case compile.compile(project, plan.source) {
    Error(message) -> #(state, Error(CompileError(message)))
    Ok(package) ->
      case hotload.reload(project) {
        Error(message) -> {
          compile.restore(project, previous)
          #(state, Error(CompileError(message)))
        }
        Ok(_) ->
          case apply_calls(state.runtime_store, plan.calls) {
            Error(message) -> {
              compile.restore(project, previous)
              #(state, Error(RuntimeError(message)))
            }
            Ok(#(store, values)) -> {
              let state =
                commit(state, plan, items, next_id, store)
                |> refresh_types(package, plan.calls)
              let outcomes = make_outcomes(items, plan.calls, values, state)
              #(state, Ok(outcomes))
            }
          }
      }
  }
}

fn commit(
  state: HarnessState,
  plan: Plan,
  items: List(Item),
  next_id: Int,
  store: dict.Dict(String, Dynamic),
) -> HarnessState {
  let table =
    list.fold(
      codegen.binding_updates(items, plan.calls),
      state.symbol_table,
      fn(table, pair) { dict.insert(table, pair.0, pair.1) },
    )
  HarnessState(
    module_source: plan.source,
    body: plan.body,
    symbol_table: table,
    runtime_store: store,
    imports: plan.imports,
    next_entry_id: next_id,
  )
}

fn apply_calls(
  store: dict.Dict(String, Dynamic),
  calls: List(Call),
) -> Result(#(dict.Dict(String, Dynamic), List(#(Call, Dynamic))), String) {
  list.try_fold(calls, #(store, []), fn(acc, call) {
    let #(store, done) = acc
    use #(store_as, value) <- result.try(run_call(store, call))
    let store = dict.insert(store, store_as, value)
    Ok(#(store, list.append(done, [#(call, value)])))
  })
}

fn run_call(
  store: dict.Dict(String, Dynamic),
  call: Call,
) -> Result(#(String, Dynamic), String) {
  case call {
    codegen.ApplyFn(entry_fn:, arg_fns:, store_as:, ..) -> {
      use args <- result.try(resolve(store, arg_fns))
      use value <- result.try(hotload.apply(entry_fn, args))
      Ok(#(store_as, value))
    }
    codegen.Project(from:, index:, store_as:, ..) -> {
      use whole <- result.try(
        dict.get(store, from)
        |> result.replace_error("Missing cached value for " <> from),
      )
      Ok(#(store_as, hotload.tuple_element(whole, index)))
    }
  }
}

fn resolve(
  store: dict.Dict(String, Dynamic),
  arg_fns: List(String),
) -> Result(List(Dynamic), String) {
  list.try_map(arg_fns, fn(name) {
    dict.get(store, name)
    |> result.replace_error("Missing cached value for " <> name)
  })
}

fn make_outcomes(
  items: List(Item),
  calls: List(Call),
  values: List(#(Call, Dynamic)),
  state: HarnessState,
) -> List(Outcome) {
  let import_outcomes =
    list.filter_map(items, fn(item) {
      case item {
        ImportItem(spec:, source: _) -> Ok(Imported(spec.module))
        _ -> Error(Nil)
      }
    })
  let def_outcomes =
    list.filter_map(items, fn(item) {
      case item {
        DefinitionItem(name:, captured_values: [], ..) ->
          Ok(Defined(name, lookup_binding_type(state, name)))
        _ -> Error(Nil)
      }
    })
  let value_outcomes =
    list.filter_map(values, fn(pair) {
      let #(call, value) = pair
      case call_print(call) {
        False -> Error(Nil)
        True -> Ok(Printed(string.inspect(value), type_for_call(state, call)))
      }
    })
  let _ = calls
  list.flatten([import_outcomes, def_outcomes, value_outcomes])
}

fn call_print(call: Call) -> Bool {
  case call {
    codegen.ApplyFn(print:, ..) -> print
    codegen.Project(print:, ..) -> print
  }
}

fn call_bind_names(call: Call) -> List(String) {
  case call {
    codegen.ApplyFn(bind_names:, ..) -> bind_names
    codegen.Project(bind_names:, ..) -> bind_names
  }
}

fn type_for_call(state: HarnessState, call: Call) -> String {
  case call_bind_names(call) {
    [name, ..] -> lookup_binding_type(state, name)
    [] -> ""
  }
}

fn lookup_binding_type(state: HarnessState, name: String) -> String {
  case dict.get(state.symbol_table, name) {
    Ok(Value(_, gleam_type)) -> gleam_type
    Ok(Definition(_, gleam_type)) -> gleam_type
    Error(_) -> ""
  }
}

fn env_of(state: HarnessState) -> Env {
  classify.env_from_state(dict.to_list(state.symbol_table), state.imports)
}

fn refresh_types(
  state: HarnessState,
  package: Package,
  calls: List(Call),
) -> HarnessState {
  let scratch = state.scratch_module_name
  case dict.get(package.modules, scratch) {
    Error(_) -> state
    Ok(module) -> {
      let #(table, extra_imports) =
        dict.to_list(state.symbol_table)
        |> list.fold(#(dict.new(), state.imports), fn(acc, pair) {
          let #(table, imports) = acc
          let #(name, kind) = pair
          let #(kind, more) = typed_kind(kind, module, scratch, imports, calls)
          #(dict.insert(table, name, kind), list.append(imports, more))
        })
      let imports = merge_all_imports(state.imports, extra_imports)
      HarnessState(
        ..state,
        symbol_table: table,
        imports:,
        module_source: codegen.render(imports, state.body),
      )
    }
  }
}

fn projected_type(
  store_as: String,
  calls: List(Call),
  module: package_interface.Module,
  scratch: String,
  imports: List(ImportSpec),
) -> Result(#(BindingKind, List(ImportSpec)), Nil) {
  case
    list.find(calls, fn(call) {
      case call {
        codegen.Project(store_as: key, ..) if key == store_as -> True
        _ -> False
      }
    })
  {
    Error(_) -> Error(Nil)
    Ok(codegen.ApplyFn(..)) -> Error(Nil)
    Ok(codegen.Project(from:, index:, ..)) ->
      case dict.get(module.functions, from) {
        Error(_) -> Error(Nil)
        Ok(function) ->
          case function.return {
            package_interface.Tuple(elements) ->
              case list_at(elements, index - 1) {
                Ok(type_) -> {
                  let #(text, extra) = types.render(type_, scratch, imports)
                  Ok(#(Value(store_as, text), extra))
                }
                Error(_) -> Error(Nil)
              }
            _ -> Error(Nil)
          }
      }
  }
}

fn list_at(items: List(a), index: Int) -> Result(a, Nil) {
  case items, index {
    [first, ..], 0 -> Ok(first)
    [_, ..rest], n if n > 0 -> list_at(rest, n - 1)
    _, _ -> Error(Nil)
  }
}

fn typed_kind(
  kind: BindingKind,
  module: package_interface.Module,
  scratch: String,
  imports: List(ImportSpec),
  calls: List(Call),
) -> #(BindingKind, List(ImportSpec)) {
  case kind {
    Value(entry_fn, previous) ->
      case projected_type(entry_fn, calls, module, scratch, imports) {
        Ok(result) -> result
        Error(_) ->
          case dict.get(module.functions, entry_fn) {
            Ok(function) -> {
              let #(text, extra) =
                types.render(function.return, scratch, imports)
              #(Value(entry_fn, text), extra)
            }
            Error(_) -> #(Value(entry_fn, previous), [])
          }
      }
    Definition(real_name, previous) ->
      case dict.get(module.functions, real_name) {
        Ok(function) -> {
          let #(text, extra) =
            types.render_function(
              function.parameters,
              function.return,
              scratch,
              imports,
            )
          #(Definition(real_name, text), extra)
        }
        Error(_) ->
          case dict.get(module.constants, real_name) {
            Ok(constant) -> {
              let #(text, extra) =
                types.render(constant.type_, scratch, imports)
              #(Definition(real_name, text), extra)
            }
            Error(_) ->
              case dict.get(module.types, real_name) {
                Ok(_) -> #(Definition(real_name, "type " <> real_name), [])
                Error(_) ->
                  case dict.get(module.type_aliases, real_name) {
                    Ok(_) -> #(Definition(real_name, "type " <> real_name), [])
                    Error(_) -> #(Definition(real_name, previous), [])
                  }
              }
          }
      }
  }
}

fn merge_all_imports(
  left: List(ImportSpec),
  right: List(ImportSpec),
) -> List(ImportSpec) {
  list.fold(right, left, fn(acc, spec) {
    case
      list.find(acc, fn(existing) {
        existing.module == spec.module && existing.alias == spec.alias
      })
    {
      Ok(_) -> acc
      Error(_) -> list.append(acc, [spec])
    }
  })
}
