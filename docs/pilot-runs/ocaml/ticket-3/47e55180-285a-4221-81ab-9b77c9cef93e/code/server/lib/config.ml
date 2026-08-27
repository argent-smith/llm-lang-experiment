type t = { data_dir : string; port : int }

type error =
  | Missing_data_dir
  | Unknown_argument of string
  | Missing_value of string
  | Invalid_port of string

let error_message = function
  | Missing_data_dir -> "--data-dir is required (or set SYNCBOX_DATA_DIR)"
  | Unknown_argument arg -> Printf.sprintf "unknown argument: %s" arg
  | Missing_value flag -> Printf.sprintf "missing value for %s" flag
  | Invalid_port value -> Printf.sprintf "invalid port value: %s" value

let default_port = 8080

(* [env_data_dir]/[env_port] are SYNCBOX_DATA_DIR/SYNCBOX_PORT; [args] are
   the CLI arguments (argv without argv.(0)). Flags take precedence over
   the environment. *)
let parse ~env_data_dir ~env_port args =
  let port_of_string value =
    match int_of_string_opt value with
    | Some p -> Ok p
    | None -> Error (Invalid_port value)
  in
  match
    match env_port with
    | None -> Ok default_port
    | Some p -> port_of_string p
  with
  | Error _ as e -> e
  | Ok initial_port -> (
      let data_dir = ref env_data_dir in
      let port = ref initial_port in
      let rec go = function
        | [] -> Ok ()
        | "--data-dir" :: value :: rest ->
            data_dir := Some value;
            go rest
        | "--port" :: value :: rest -> (
            match port_of_string value with
            | Ok p ->
                port := p;
                go rest
            | Error _ as e -> e)
        | [ (("--data-dir" | "--port") as flag) ] ->
            Error (Missing_value flag)
        | arg :: _ -> Error (Unknown_argument arg)
      in
      match go args with
      | Error _ as e -> e
      | Ok () -> (
          match !data_dir with
          | None -> Error Missing_data_dir
          | Some data_dir -> Ok { data_dir; port = !port }))
