import glance
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import repl/source
import repl/state.{
  type BindingKind, type ImportSpec, type Unqualified, Definition, ImportSpec,
  Unqualified, Value,
}

const wrap_prefix = "pub fn temp() {\n"

const wrap_suffix = "\n}\n"

pub type Env {
  Env(
    value_names: List(String),
    definition_names: List(String),
    import_names: List(String),
  )
}

pub type DefKind {
  FnDef
  TypeDef
  TypeAliasDef
  ConstDef
}

pub type Item {
  ImportItem(spec: ImportSpec, source: String)
  DefinitionItem(
    name: String,
    kind: DefKind,
    source: String,
    captured_values: List(String),
  )
  ValueItem(
    names: List(String),
    rhs: String,
    pattern: String,
    simple: Bool,
    is_assert: Bool,
    params: List(String),
    source: String,
  )
}

pub type ClassifyResult {
  Items(List(Item))
  ClassifyEmpty
  ClassifyIncomplete
  ClassifyError(String)
}

pub fn env_from_state(
  symbol_table: List(#(String, BindingKind)),
  imports: List(ImportSpec),
) -> Env {
  let value_names =
    list.filter_map(symbol_table, fn(pair) {
      case pair.1 {
        Value(_, _) -> Ok(pair.0)
        Definition(_, _) -> Error(Nil)
      }
    })
  let definition_names =
    list.filter_map(symbol_table, fn(pair) {
      case pair.1 {
        Definition(name, _) -> Ok(name)
        Value(_, _) -> Error(Nil)
      }
    })
  let import_names = list.flat_map(imports, import_bound_names)
  Env(value_names:, definition_names:, import_names:)
}

pub fn empty_env() -> Env {
  Env(value_names: [], definition_names: [], import_names: [])
}

pub fn is_incomplete(src: String) -> Bool {
  case classify(src, empty_env()) {
    ClassifyIncomplete -> True
    _ -> False
  }
}

pub fn classify(src: String, env: Env) -> ClassifyResult {
  let trimmed = string.trim(src)
  case trimmed {
    "" -> ClassifyEmpty
    _ -> classify_lines(string.split(src, "\n"), "", [], env)
  }
}

fn classify_lines(
  lines: List(String),
  acc: String,
  items: List(Item),
  env: Env,
) -> ClassifyResult {
  case lines {
    [] ->
      case string.trim(acc) {
        "" -> finish(items)
        _ ->
          case classify_one(acc, env) {
            Items(more) -> finish(list.append(items, more))
            ClassifyEmpty -> finish(items)
            other -> other
          }
      }
    [line, ..rest] -> {
      let acc2 = source.join_line(acc, line)
      case string.trim(acc2) {
        "" -> classify_lines(rest, "", items, env)
        _ ->
          case classify_one(acc2, env) {
            Items(more) ->
              classify_lines(
                rest,
                "",
                list.append(items, more),
                extend_env(env, more),
              )
            ClassifyEmpty -> classify_lines(rest, "", items, env)
            ClassifyIncomplete -> classify_lines(rest, acc2, items, env)
            ClassifyError(_) as error -> error
          }
      }
    }
  }
}

fn finish(items: List(Item)) -> ClassifyResult {
  case items {
    [] -> ClassifyEmpty
    _ -> Items(items)
  }
}

fn classify_one(src: String, env: Env) -> ClassifyResult {
  let trimmed = string.trim(src)
  case trimmed {
    "" -> ClassifyEmpty
    _ ->
      case source.unmatched_delimiters(src) {
        True -> ClassifyIncomplete
        False ->
          case glance.module(src) {
            Ok(module) -> from_module(src, module, env)
            Error(glance.UnexpectedEndOfInput) -> ClassifyIncomplete
            Error(glance.UnexpectedToken(_, _)) -> from_wrapped(src, env)
          }
      }
  }
}

fn from_module(src: String, module: glance.Module, env: Env) -> ClassifyResult {
  let imports = list.map(module.imports, fn(def) { import_item(src, def, 0) })
  let functions =
    list.map(module.functions, fn(def) { function_item(src, def, 0, env) })
  let types = list.map(module.custom_types, fn(def) { type_item(src, def, 0) })
  let aliases =
    list.map(module.type_aliases, fn(def) { alias_item(src, def, 0) })
  let constants =
    list.map(module.constants, fn(def) { const_item(src, def, 0) })
  let items = list.flatten([imports, functions, types, aliases, constants])
  case items {
    [] -> from_wrapped(src, env)
    _ -> Items(items)
  }
}

fn from_wrapped(src: String, env: Env) -> ClassifyResult {
  let wrapped = wrap_prefix <> src <> wrap_suffix
  case glance.module(wrapped) {
    Ok(module) ->
      case module.functions {
        [def] -> statements_from(src, def.definition.body, env)
        _ -> ClassifyError("Could not classify snippet")
      }
    Error(glance.UnexpectedEndOfInput) -> ClassifyIncomplete
    Error(glance.UnexpectedToken(token:, position: _)) ->
      ClassifyError("Syntax error near " <> string.inspect(token))
  }
}

fn statements_from(
  src: String,
  statements: List(glance.Statement),
  env: Env,
) -> ClassifyResult {
  case statements {
    [] -> ClassifyEmpty
    _ -> {
      let offset = string.byte_size(wrap_prefix)
      let items =
        list.map(statements, fn(statement) {
          statement_item(src, statement, offset, env)
        })
      Items(items)
    }
  }
}

fn statement_item(
  src: String,
  statement: glance.Statement,
  offset: Int,
  env: Env,
) -> Item {
  case statement {
    glance.Assignment(location:, kind:, pattern:, annotation: _, value:) -> {
      let names = pattern_names(pattern)
      let rhs =
        source.slice_bytes(
          src,
          value.location.start - offset,
          value.location.end - offset,
        )
      let pattern_src =
        source.slice_bytes(
          src,
          pattern_start(pattern) - offset,
          pattern_end(pattern) - offset,
        )
      let is_assert = case kind {
        glance.Let -> False
        glance.LetAssert(_) -> True
      }
      let simple = case pattern, names {
        glance.PatternVariable(_, _), [_] -> True
        _, _ -> False
      }
      let params = free_params(assignment_vars(value, pattern, kind), env)
      let original =
        source.slice_bytes(src, location.start - offset, location.end - offset)
      ValueItem(
        names:,
        rhs:,
        pattern: pattern_src,
        simple:,
        is_assert:,
        params:,
        source: original,
      )
    }
    glance.Expression(expression) ->
      expression_item(src, expression, offset, env)
    glance.Assert(location:, expression:, message: _) ->
      expression_item_from_span(
        src,
        expression,
        location.start,
        location.end,
        offset,
        env,
      )
    glance.Use(location:, patterns: _, function:) ->
      expression_item_from_span(
        src,
        function,
        location.start,
        location.end,
        offset,
        env,
      )
  }
}

fn expression_item(
  src: String,
  expression: glance.Expression,
  offset: Int,
  env: Env,
) -> Item {
  expression_item_from_span(
    src,
    expression,
    expression_start(expression),
    expression_end(expression),
    offset,
    env,
  )
}

fn expression_item_from_span(
  src: String,
  expression: glance.Expression,
  start: Int,
  end: Int,
  offset: Int,
  env: Env,
) -> Item {
  let text = source.slice_bytes(src, start - offset, end - offset)
  ValueItem(
    names: [],
    rhs: text,
    pattern: "",
    simple: True,
    is_assert: False,
    params: free_params(expr_vars(expression, []), env),
    source: text,
  )
}

fn import_item(
  src: String,
  def: glance.Definition(glance.Import),
  offset: Int,
) -> Item {
  let import_ = def.definition
  let spec =
    ImportSpec(
      module: import_.module,
      alias: assignment_alias(import_.alias),
      types: list.map(import_.unqualified_types, unqualified),
      values: list.map(import_.unqualified_values, unqualified),
    )
  ImportItem(spec:, source: slice_def(src, def, import_.location, offset))
}

fn function_item(
  src: String,
  def: glance.Definition(glance.Function),
  offset: Int,
  env: Env,
) -> Item {
  let function = def.definition
  let source =
    force_pub(
      slice_def(src, def, function.location, offset),
      function.publicity,
    )
  let bound = list.filter_map(function.parameters, fn_param_name)
  let free = statements_vars(function.body, bound)
  DefinitionItem(
    name: function.name,
    kind: FnDef,
    source:,
    captured_values: free_params(free, env),
  )
}

fn type_item(
  src: String,
  def: glance.Definition(glance.CustomType),
  offset: Int,
) -> Item {
  let type_ = def.definition
  DefinitionItem(
    name: type_.name,
    kind: TypeDef,
    source: force_pub(
      slice_def(src, def, type_.location, offset),
      type_.publicity,
    ),
    captured_values: [],
  )
}

fn alias_item(
  src: String,
  def: glance.Definition(glance.TypeAlias),
  offset: Int,
) -> Item {
  let alias = def.definition
  DefinitionItem(
    name: alias.name,
    kind: TypeAliasDef,
    source: force_pub(
      slice_def(src, def, alias.location, offset),
      alias.publicity,
    ),
    captured_values: [],
  )
}

fn const_item(
  src: String,
  def: glance.Definition(glance.Constant),
  offset: Int,
) -> Item {
  let constant = def.definition
  DefinitionItem(
    name: constant.name,
    kind: ConstDef,
    source: force_pub(
      slice_def(src, def, constant.location, offset),
      constant.publicity,
    ),
    captured_values: [],
  )
}

fn slice_def(
  src: String,
  def: glance.Definition(a),
  location: glance.Span,
  offset: Int,
) -> String {
  let _ = def
  source.slice_bytes(src, location.start - offset, location.end - offset)
}

fn force_pub(src: String, publicity: glance.Publicity) -> String {
  case publicity {
    glance.Public -> src
    glance.Private -> insert_pub(src)
  }
}

fn insert_pub(src: String) -> String {
  insert_pub_loop(src, "")
}

fn insert_pub_loop(remaining: String, acc: String) -> String {
  case remaining {
    "pub " <> _ -> acc <> remaining
    "pub\n" <> _ -> acc <> remaining
    "fn " <> _ | "fn\n" <> _ -> acc <> "pub " <> remaining
    "type " <> _ | "type\n" <> _ -> acc <> "pub " <> remaining
    "const " <> _ | "const\n" <> _ -> acc <> "pub " <> remaining
    "opaque " <> _ -> acc <> "pub " <> remaining
    "" -> acc
    _ ->
      case string.pop_grapheme(remaining) {
        Ok(#(g, rest)) -> insert_pub_loop(rest, acc <> g)
        Error(_) -> acc <> remaining
      }
  }
}

fn assignment_alias(alias: Option(glance.AssignmentName)) -> Option(String) {
  case alias {
    Some(glance.Named(name)) -> Some(name)
    Some(glance.Discarded(_)) | None -> None
  }
}

fn unqualified(item: glance.UnqualifiedImport) -> Unqualified {
  Unqualified(name: item.name, alias: item.alias)
}

fn fn_param_name(param: glance.FunctionParameter) -> Result(String, Nil) {
  case param.name {
    glance.Named(name) -> Ok(name)
    glance.Discarded(_) -> Error(Nil)
  }
}

fn import_bound_names(spec: ImportSpec) -> List(String) {
  let alias = state.import_alias(spec)
  let values =
    list.map(spec.values, fn(item) {
      case item.alias {
        Some(name) -> name
        None -> item.name
      }
    })
  let types =
    list.map(spec.types, fn(item) {
      case item.alias {
        Some(name) -> name
        None -> item.name
      }
    })
  [alias, ..list.append(values, types)]
}

fn extend_env(env: Env, items: List(Item)) -> Env {
  list.fold(items, env, fn(env, item) {
    case item {
      ImportItem(spec:, source: _) ->
        Env(
          ..env,
          import_names: list.append(env.import_names, import_bound_names(spec)),
        )
      DefinitionItem(name:, kind: _, source: _, captured_values: _) ->
        Env(..env, definition_names: [name, ..env.definition_names])
      ValueItem(names:, ..) ->
        Env(..env, value_names: list.append(env.value_names, names))
    }
  })
}

fn free_params(names: List(String), env: Env) -> List(String) {
  list.filter(names, fn(name) {
    list.contains(env.value_names, name)
    && !list.contains(env.import_names, name)
    && !is_prelude(name)
  })
}

fn is_prelude(name: String) -> Bool {
  case name {
    "True" | "False" | "Nil" | "Ok" | "Error" -> True
    _ -> False
  }
}

pub fn pattern_names(pattern: glance.Pattern) -> List(String) {
  pattern_names_acc(pattern, [])
}

fn pattern_names_acc(
  pattern: glance.Pattern,
  acc: List(String),
) -> List(String) {
  case pattern {
    glance.PatternVariable(_, name) -> push_unique(acc, name)
    glance.PatternAssignment(_, inner, name) ->
      pattern_names_acc(inner, push_unique(acc, name))
    glance.PatternTuple(_, elements) ->
      list.fold(elements, acc, fn(acc, p) { pattern_names_acc(p, acc) })
    glance.PatternList(_, elements, tail) -> {
      let acc =
        list.fold(elements, acc, fn(acc, p) { pattern_names_acc(p, acc) })
      case tail {
        Some(tail) -> pattern_names_acc(tail, acc)
        None -> acc
      }
    }
    glance.PatternVariant(_, _, _, arguments, _) ->
      list.fold(arguments, acc, fn(acc, field) {
        case field {
          glance.LabelledField(_, _, item) -> pattern_names_acc(item, acc)
          glance.UnlabelledField(item) -> pattern_names_acc(item, acc)
          glance.ShorthandField(label:, location: _) -> push_unique(acc, label)
        }
      })
    glance.PatternConcatenate(_, _, prefix_name, rest_name) -> {
      let acc = case prefix_name {
        Some(glance.Named(name)) -> push_unique(acc, name)
        Some(glance.Discarded(_)) | None -> acc
      }
      case rest_name {
        glance.Named(name) -> push_unique(acc, name)
        glance.Discarded(_) -> acc
      }
    }
    glance.PatternBitString(_, segments) ->
      list.fold(segments, acc, fn(acc, segment) {
        pattern_names_acc(segment.0, acc)
      })
    glance.PatternInt(_, _)
    | glance.PatternFloat(_, _)
    | glance.PatternString(_, _)
    | glance.PatternDiscard(_, _) -> acc
  }
}

fn assignment_vars(
  value: glance.Expression,
  pattern: glance.Pattern,
  kind: glance.AssignmentKind,
) -> List(String) {
  let value_vars = expr_vars(value, [])
  let message_vars = case kind {
    glance.Let -> []
    glance.LetAssert(message) ->
      case message {
        Some(expression) -> expr_vars(expression, [])
        None -> []
      }
  }
  let _ = pattern
  list.append(value_vars, message_vars)
}

fn statements_vars(
  statements: List(glance.Statement),
  bound: List(String),
) -> List(String) {
  let #(_bound, vars) =
    list.fold(statements, #(bound, []), fn(pair, statement) {
      let #(bound, vars) = pair
      case statement {
        glance.Assignment(kind:, pattern:, value:, ..) -> {
          let vars =
            unique_append(
              vars,
              minus(assignment_vars(value, pattern, kind), bound),
            )
          #(list.append(bound, pattern_names(pattern)), vars)
        }
        glance.Expression(expression) -> #(
          bound,
          unique_append(vars, minus(expr_vars(expression, bound), [])),
        )
        glance.Assert(expression:, message:, ..) -> {
          let extra = case message {
            Some(msg) -> expr_vars(msg, bound)
            None -> []
          }
          #(
            bound,
            unique_append(
              vars,
              list.append(expr_vars(expression, bound), extra),
            ),
          )
        }
        glance.Use(patterns:, function:, ..) -> {
          let names =
            list.flat_map(patterns, fn(p) { pattern_names(p.pattern) })
          #(
            list.append(bound, names),
            unique_append(vars, expr_vars(function, bound)),
          )
        }
      }
    })
  vars
}

fn expr_vars(
  expression: glance.Expression,
  bound: List(String),
) -> List(String) {
  case expression {
    glance.Variable(_, name) ->
      case list.contains(bound, name) {
        True -> []
        False -> [name]
      }
    glance.Int(_, _) | glance.Float(_, _) | glance.String(_, _) -> []
    glance.NegateInt(_, inner) | glance.NegateBool(_, inner) ->
      expr_vars(inner, bound)
    glance.Block(_, statements) -> statements_vars(statements, bound)
    glance.Panic(_, message) | glance.Todo(_, message) ->
      optional_expr_vars(message, bound)
    glance.Tuple(_, elements) ->
      list.flat_map(elements, fn(e) { expr_vars(e, bound) })
    glance.List(_, elements, rest) -> {
      let rest_vars = case rest {
        Some(e) -> expr_vars(e, bound)
        None -> []
      }
      list.append(
        list.flat_map(elements, fn(e) { expr_vars(e, bound) }),
        rest_vars,
      )
    }
    glance.Fn(_, arguments, _, body) -> {
      let params =
        list.filter_map(arguments, fn(p) {
          case p.name {
            glance.Named(name) -> Ok(name)
            glance.Discarded(_) -> Error(Nil)
          }
        })
      statements_vars(body, list.append(bound, params))
    }
    glance.RecordUpdate(_, _, _, record, fields) ->
      list.append(
        expr_vars(record, bound),
        list.flat_map(fields, fn(field) {
          case field.item {
            Some(e) -> expr_vars(e, bound)
            None -> []
          }
        }),
      )
    glance.FieldAccess(_, container, _) -> expr_vars(container, bound)
    glance.Call(_, function, arguments) ->
      list.append(
        expr_vars(function, bound),
        list.flat_map(arguments, field_expr_vars(_, bound)),
      )
    glance.TupleIndex(_, tuple, _) -> expr_vars(tuple, bound)
    glance.FnCapture(_, _, function, before, after) ->
      list.flatten([
        expr_vars(function, bound),
        list.flat_map(before, field_expr_vars(_, bound)),
        list.flat_map(after, field_expr_vars(_, bound)),
      ])
    glance.BitString(_, segments) ->
      list.flat_map(segments, fn(segment) { expr_vars(segment.0, bound) })
    glance.Case(_, subjects, clauses) ->
      list.append(
        list.flat_map(subjects, fn(e) { expr_vars(e, bound) }),
        list.flat_map(clauses, fn(clause) {
          let names =
            list.flat_map(clause.patterns, fn(alts) {
              list.flat_map(alts, pattern_names)
            })
          let bound = list.append(bound, names)
          let guard = case clause.guard {
            Some(g) -> expr_vars(g, bound)
            None -> []
          }
          list.append(guard, expr_vars(clause.body, bound))
        }),
      )
    glance.BinaryOperator(_, _, left, right) ->
      list.append(expr_vars(left, bound), expr_vars(right, bound))
    glance.Echo(_, expression, message) ->
      list.append(
        optional_expr_vars(expression, bound),
        optional_expr_vars(message, bound),
      )
  }
}

fn field_expr_vars(
  field: glance.Field(glance.Expression),
  bound: List(String),
) -> List(String) {
  case field {
    glance.LabelledField(_, _, item) -> expr_vars(item, bound)
    glance.UnlabelledField(item) -> expr_vars(item, bound)
    glance.ShorthandField(_, _) -> []
  }
}

fn optional_expr_vars(
  expression: Option(glance.Expression),
  bound: List(String),
) -> List(String) {
  case expression {
    Some(e) -> expr_vars(e, bound)
    None -> []
  }
}

fn expression_start(expression: glance.Expression) -> Int {
  expression.location.start
}

fn expression_end(expression: glance.Expression) -> Int {
  expression.location.end
}

fn pattern_start(pattern: glance.Pattern) -> Int {
  pattern.location.start
}

fn pattern_end(pattern: glance.Pattern) -> Int {
  pattern.location.end
}

fn minus(names: List(String), bound: List(String)) -> List(String) {
  list.filter(names, fn(name) { !list.contains(bound, name) })
}

fn unique_append(acc: List(String), extra: List(String)) -> List(String) {
  list.fold(extra, acc, push_unique)
}

fn push_unique(acc: List(String), name: String) -> List(String) {
  case list.contains(acc, name) {
    True -> acc
    False -> list.append(acc, [name])
  }
}
