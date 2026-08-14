import gleam/json
import gleam/package_interface.{type Package}
import gleam/result
import gleam/string
import repl/codegen
import repl/project as host
import repl/state.{type Project}
import shellout
import simplifile

pub fn write_scratch(
  project: Project,
  generation: Int,
  source: String,
) -> Result(Nil, String) {
  let dir = host.join(project.root, "src")
  let path = host.scratch_path(project, generation)
  use _ <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(e) { "Could not create src/: " <> string.inspect(e) }),
  )
  host.clear_scratch_files(project)
  simplifile.write(to: path, contents: source)
  |> result.map_error(fn(e) {
    "Could not write scratch module: " <> string.inspect(e)
  })
}

pub fn compile(
  project: Project,
  generation: Int,
  source: String,
) -> Result(#(Package, String), String) {
  let path = host.scratch_path(project, generation)
  use _ <- result.try(write_scratch(project, generation, source))
  case
    run_gleam(project, ["build", "--target", "erlang", "--no-print-progress"])
  {
    Error(message) -> {
      host.delete_scratch(project, generation)
      Error(message)
    }
    Ok(output) ->
      case export_interface(project) {
        Ok(package) -> Ok(#(package, output))
        Error(message) -> {
          host.delete_scratch(project, generation)
          Error(codegen.polish_compiler_error(message, path))
        }
      }
  }
}

fn export_interface(project: Project) -> Result(Package, String) {
  use _ <- result.try(
    run_gleam(project, [
      "export",
      "package-interface",
      "--out",
      project.interface_path,
    ]),
  )
  use json_src <- result.try(
    simplifile.read(project.interface_path)
    |> result.map_error(fn(_) { "Could not read package interface JSON" }),
  )
  json.parse(from: json_src, using: package_interface.decoder())
  |> result.map_error(fn(e) {
    "Could not decode package interface: " <> string.inspect(e)
  })
}

fn run_gleam(project: Project, args: List(String)) -> Result(String, String) {
  case shellout.command(run: "gleam", with: args, in: project.root, opt: []) {
    Ok(output) -> Ok(output)
    Error(#(_status, message)) -> Error(string.trim(message))
  }
}
