import gleam/int
import gleam/list
import gleam/string
import repl/history

pub type Event {
  Char(String)
  Enter
  Backspace
  Delete
  Left
  Right
  Up
  Down
  Home
  End
  CtrlA
  CtrlE
  CtrlU
  CtrlK
  CtrlW
  CtrlR
  CtrlC
  CtrlD
  CtrlL
  Escape
}

pub type Mode {
  Editing
  Searching(query: String, skip: Int)
}

pub type Editor {
  Editor(
    prompt: String,
    buffer: String,
    cursor: Int,
    history: List(String),
    history_index: Int,
    draft: String,
    mode: Mode,
  )
}

pub type Step {
  Continue(Editor)
  Submit(line: String, history: List(String))
  Quit
}

pub fn new(prompt: String, history: List(String)) -> Editor {
  Editor(
    prompt:,
    buffer: "",
    cursor: 0,
    history:,
    history_index: 0,
    draft: "",
    mode: Editing,
  )
}

pub fn apply(editor: Editor, event: Event) -> Step {
  case editor.mode {
    Searching(query, skip) -> apply_search(editor, query, skip, event)
    Editing -> apply_edit(editor, event)
  }
}

fn apply_edit(editor: Editor, event: Event) -> Step {
  case event {
    Enter -> Submit(editor.buffer, history.add(editor.history, editor.buffer))
    CtrlD ->
      case editor.buffer {
        "" -> Quit
        _ -> Continue(delete_forward(editor))
      }
    CtrlC ->
      Continue(
        Editor(..editor, buffer: "", cursor: 0, history_index: 0, draft: ""),
      )
    CtrlR -> start_search(editor)
    Escape -> Continue(editor)
    Up -> Continue(move_history(editor, editor.history_index + 1))
    Down -> Continue(move_history(editor, editor.history_index - 1))
    Left -> Continue(move_cursor(editor, editor.cursor - 1))
    Right -> Continue(move_cursor(editor, editor.cursor + 1))
    Home | CtrlA -> Continue(move_cursor(editor, 0))
    End | CtrlE -> Continue(move_cursor(editor, string.length(editor.buffer)))
    Backspace -> Continue(backspace(editor))
    Delete -> Continue(delete_forward(editor))
    CtrlU -> Continue(Editor(..editor, buffer: "", cursor: 0))
    CtrlK -> Continue(kill_to_end(editor))
    CtrlW -> Continue(kill_word(editor))
    CtrlL -> Continue(editor)
    Char(ch) -> Continue(insert(editor, ch))
  }
}

fn apply_search(
  editor: Editor,
  query: String,
  skip: Int,
  event: Event,
) -> Step {
  case event {
    Enter ->
      case editor.buffer {
        "" -> Continue(end_search(editor, editor.draft))
        line -> Submit(line, history.add(editor.history, line))
      }
    Escape | CtrlC -> Continue(end_search(editor, editor.draft))
    CtrlR ->
      Continue(
        set_search(editor, query, case query {
          "" -> 0
          _ -> skip + 1
        }),
      )
    Backspace -> Continue(set_search(editor, string.drop_end(query, 1), 0))
    Char(ch) -> Continue(set_search(editor, query <> ch, 0))
    CtrlD ->
      case query {
        "" -> Continue(end_search(editor, editor.draft))
        _ -> Continue(editor)
      }
    _ -> Continue(editor)
  }
}

fn start_search(editor: Editor) -> Step {
  Continue(set_search(Editor(..editor, draft: editor.buffer), editor.buffer, 0))
}

fn set_search(editor: Editor, query: String, skip: Int) -> Editor {
  let #(buffer, skip) = case history.search(editor.history, query, skip) {
    Ok(#(line, found)) -> #(line, found)
    Error(_) -> #("", skip)
  }
  Editor(
    ..editor,
    buffer:,
    cursor: string.length(buffer),
    mode: Searching(query, skip),
  )
}

fn end_search(editor: Editor, buffer: String) -> Editor {
  Editor(
    ..editor,
    buffer:,
    cursor: string.length(buffer),
    history_index: 0,
    mode: Editing,
  )
}

fn move_history(editor: Editor, index: Int) -> Editor {
  let max = list.length(editor.history)
  case index <= 0 {
    True ->
      Editor(
        ..editor,
        buffer: editor.draft,
        cursor: string.length(editor.draft),
        history_index: 0,
      )
    False -> {
      let index = int.min(index, max)
      case history.at(editor.history, index - 1) {
        Error(_) -> editor
        Ok(line) -> {
          let draft = case editor.history_index {
            0 -> editor.buffer
            _ -> editor.draft
          }
          Editor(
            ..editor,
            buffer: line,
            cursor: string.length(line),
            history_index: index,
            draft:,
          )
        }
      }
    }
  }
}

fn move_cursor(editor: Editor, cursor: Int) -> Editor {
  let cursor = int.max(0, int.min(cursor, string.length(editor.buffer)))
  Editor(..editor, cursor:)
}

fn insert(editor: Editor, ch: String) -> Editor {
  let #(left, right) = split_at(editor.buffer, editor.cursor)
  let buffer = left <> ch <> right
  Editor(..editor, buffer:, cursor: editor.cursor + string.length(ch))
}

fn backspace(editor: Editor) -> Editor {
  case editor.cursor {
    0 -> editor
    _ -> {
      let #(left, right) = split_at(editor.buffer, editor.cursor)
      let left = string.drop_end(left, 1)
      Editor(..editor, buffer: left <> right, cursor: editor.cursor - 1)
    }
  }
}

fn delete_forward(editor: Editor) -> Editor {
  let #(left, right) = split_at(editor.buffer, editor.cursor)
  Editor(..editor, buffer: left <> string.drop_start(right, 1))
}

fn kill_to_end(editor: Editor) -> Editor {
  let #(left, _) = split_at(editor.buffer, editor.cursor)
  Editor(..editor, buffer: left)
}

fn kill_word(editor: Editor) -> Editor {
  let #(left, right) = split_at(editor.buffer, editor.cursor)
  let left = drop_last_word(string.trim_end(left))
  Editor(..editor, buffer: left <> right, cursor: string.length(left))
}

fn drop_last_word(src: String) -> String {
  case string.split(src, " ") {
    [] -> ""
    parts ->
      parts
      |> list.reverse
      |> list.drop(1)
      |> list.reverse
      |> string.join(" ")
  }
}

fn split_at(src: String, index: Int) -> #(String, String) {
  let graphemes = string.to_graphemes(src)
  let #(left, right) = list.split(graphemes, index)
  #(string.concat(left), string.concat(right))
}

pub fn display(editor: Editor) -> #(String, Int) {
  case editor.mode {
    Editing -> #(
      editor.prompt <> editor.buffer,
      editor.cursor + string.length(editor.prompt),
    )
    Searching(query, skip) -> {
      let label = case history.search(editor.history, query, skip) {
        Ok(_) -> "(reverse-i-search)`"
        Error(_) -> "(failed reverse-i-search)`"
      }
      let shown = label <> query <> "': " <> editor.buffer
      #(shown, string.length(shown))
    }
  }
}
