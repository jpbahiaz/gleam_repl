import gleam/bit_array
import gleam/int
import gleam/string
import repl/editor.{type Editor, type Event, Continue, Quit, Submit}
import repl/source
import repl/style

pub type Input {
  Read(String)
  Eof
}

pub fn read_line(prompt: String, history: List(String), color: Bool) -> Input {
  case is_tty() {
    False -> cooked(prompt)
    True ->
      case tty_begin() {
        Error(_) -> cooked(prompt)
        Ok(_) -> {
          let result = raw_loop(editor.new(prompt, history), color)
          tty_end()
          result
        }
      }
  }
}

fn cooked(prompt: String) -> Input {
  case get_line(prompt) {
    Read(raw) -> Read(source.strip_newline(raw))
    Eof -> Eof
  }
}

fn raw_loop(ed: Editor, color: Bool) -> Input {
  redraw(ed, color)
  case next_event() {
    Error(_) -> {
      tty_write("\r\n")
      Eof
    }
    Ok(event) ->
      case event {
        editor.CtrlL -> {
          tty_write("\u{001b}[H\u{001b}[2J")
          raw_loop(ed, color)
        }
        _ ->
          case editor.apply(ed, event) {
            Continue(ed) -> raw_loop(ed, color)
            Quit -> {
              tty_write("\r\n")
              Eof
            }
            Submit(line, _) -> {
              tty_write("\r\n")
              Read(line)
            }
          }
      }
  }
}

fn redraw(ed: Editor, color: Bool) -> Nil {
  let #(text, cursor) = editor.display(ed)
  let painted = case ed.mode {
    editor.Editing -> style.prompt(ed.prompt, color) <> ed.buffer
    editor.Searching(_, _) -> text
  }
  let back = string.length(text) - cursor
  let suffix = case back > 0 {
    True -> "\u{001b}[" <> int.to_string(back) <> "D"
    False -> ""
  }
  tty_write("\r" <> painted <> "\u{001b}[K" <> suffix)
}

fn next_event() -> Result(Event, Nil) {
  case tty_read() {
    TtyEof -> Error(Nil)
    Byte(3) -> Ok(editor.CtrlC)
    Byte(4) -> Ok(editor.CtrlD)
    Byte(12) -> Ok(editor.CtrlL)
    Byte(10) | Byte(13) -> Ok(editor.Enter)
    Byte(8) | Byte(127) -> Ok(editor.Backspace)
    Byte(1) -> Ok(editor.CtrlA)
    Byte(5) -> Ok(editor.CtrlE)
    Byte(11) -> Ok(editor.CtrlK)
    Byte(18) -> Ok(editor.CtrlR)
    Byte(21) -> Ok(editor.CtrlU)
    Byte(23) -> Ok(editor.CtrlW)
    Byte(27) -> read_escape()
    Byte(b) if b >= 32 && b < 127 ->
      case byte_to_string(b) {
        Ok(ch) -> Ok(editor.Char(ch))
        Error(_) -> next_event()
      }
    Byte(b) if b >= 192 -> read_utf8(b)
    Byte(_) -> next_event()
  }
}

fn read_escape() -> Result(Event, Nil) {
  case tty_read() {
    TtyEof -> Ok(editor.Escape)
    Byte(91) -> read_csi("")
    Byte(_) -> Ok(editor.Escape)
  }
}

fn read_csi(acc: String) -> Result(Event, Nil) {
  case tty_read() {
    TtyEof -> Ok(editor.Escape)
    Byte(65) -> Ok(editor.Up)
    Byte(66) -> Ok(editor.Down)
    Byte(67) -> Ok(editor.Right)
    Byte(68) -> Ok(editor.Left)
    Byte(72) -> Ok(editor.Home)
    Byte(70) -> Ok(editor.End)
    Byte(126) ->
      case acc {
        "3" -> Ok(editor.Delete)
        "1" | "7" -> Ok(editor.Home)
        "4" | "8" -> Ok(editor.End)
        _ -> next_event()
      }
    Byte(b) if b >= 48 && b <= 57 || b == 59 ->
      case byte_to_string(b) {
        Ok(ch) -> read_csi(acc <> ch)
        Error(_) -> next_event()
      }
    Byte(_) -> next_event()
  }
}

fn read_utf8(first: Int) -> Result(Event, Nil) {
  let need = case first {
    b if b >= 240 -> 3
    b if b >= 224 -> 2
    _ -> 1
  }
  collect_utf8(<<first>>, need)
}

fn collect_utf8(acc: BitArray, remaining: Int) -> Result(Event, Nil) {
  case remaining {
    0 ->
      case bit_array.to_string(acc) {
        Ok(ch) -> Ok(editor.Char(ch))
        Error(_) -> next_event()
      }
    _ ->
      case tty_read() {
        Byte(b) -> collect_utf8(<<acc:bits, b>>, remaining - 1)
        TtyEof -> Error(Nil)
      }
  }
}

fn byte_to_string(b: Int) -> Result(String, Nil) {
  bit_array.to_string(<<b>>)
}

type TtyByte {
  Byte(Int)
  TtyEof
}

@external(erlang, "repl_ffi", "get_line")
fn get_line(prompt: String) -> Input

@external(erlang, "repl_ffi", "is_tty")
pub fn is_tty() -> Bool

@external(erlang, "repl_ffi", "tty_begin")
fn tty_begin() -> Result(Nil, Nil)

@external(erlang, "repl_ffi", "tty_end")
fn tty_end() -> Nil

@external(erlang, "repl_ffi", "tty_read")
fn tty_read() -> TtyByte

@external(erlang, "repl_ffi", "tty_write")
fn tty_write(text: String) -> Nil
