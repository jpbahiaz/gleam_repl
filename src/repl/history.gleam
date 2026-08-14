import gleam/int
import gleam/list
import gleam/string
import simplifile

pub const max_entries = 1000

pub fn add(entries: List(String), line: String) -> List(String) {
  let line = string.trim_end(line)
  case should_record(line) {
    False -> entries
    True ->
      case list.last(entries) {
        Ok(last) if last == line -> entries
        _ -> trim_oldest(list.append(entries, [line]))
      }
  }
}

pub fn should_record(line: String) -> Bool {
  let trimmed = string.trim(line)
  case trimmed {
    "" | ":quit" | ":q" -> False
    _ -> True
  }
}

fn trim_oldest(entries: List(String)) -> List(String) {
  let extra = list.length(entries) - max_entries
  case extra > 0 {
    True -> list.drop(entries, extra)
    False -> entries
  }
}

pub fn search(
  entries: List(String),
  query: String,
  skip: Int,
) -> Result(#(String, Int), Nil) {
  case query {
    "" -> Error(Nil)
    _ ->
      entries
      |> list.reverse
      |> drop_skip(skip)
      |> find_match(query, skip)
  }
}

fn drop_skip(entries: List(String), skip: Int) -> List(String) {
  case skip > 0 {
    True -> list.drop(entries, skip)
    False -> entries
  }
}

fn find_match(
  entries: List(String),
  query: String,
  index: Int,
) -> Result(#(String, Int), Nil) {
  case entries {
    [] -> Error(Nil)
    [first, ..rest] ->
      case string.contains(first, query) {
        True -> Ok(#(first, index))
        False -> find_match(rest, query, index + 1)
      }
  }
}

pub fn load(path: String) -> List(String) {
  case simplifile.read(path) {
    Error(_) -> []
    Ok(contents) ->
      contents
      |> string.split("\n")
      |> list.filter(fn(line) { string.trim(line) != "" })
      |> trim_oldest
  }
}

pub fn save(path: String, entries: List(String)) -> Nil {
  let _ =
    simplifile.write(to: path, contents: string.join(entries, "\n") <> "\n")
  Nil
}

pub fn at(
  entries: List(String),
  from_newest index: Int,
) -> Result(String, Nil) {
  entries
  |> list.reverse
  |> list.drop(index)
  |> list.first
}

pub fn format(entries: List(String)) -> String {
  entries
  |> list.index_map(fn(line, i) { int_pad(i + 1) <> "  " <> line })
  |> string.join("\n")
}

fn int_pad(n: Int) -> String {
  let s = int.to_string(n)
  case string.length(s) {
    1 -> "   " <> s
    2 -> "  " <> s
    3 -> " " <> s
    _ -> s
  }
}
