(* Syncbox server entry point: argument/env parsing + minimal HTTP server. *)

let usage =
  "usage: syncbox-server --data-dir <path> [--port <n>]\n\
  \  (or set SYNCBOX_DATA_DIR / SYNCBOX_PORT)\n"

let die msg =
  Printf.eprintf "syncbox-server: %s\n%s%!" msg usage;
  exit 1

let () =
  let env_data_dir = Sys.getenv_opt "SYNCBOX_DATA_DIR" in
  let env_port = Sys.getenv_opt "SYNCBOX_PORT" in
  let args = List.tl (Array.to_list Sys.argv) in
  let config =
    match Syncbox_lib.Config.parse ~env_data_dir ~env_port args with
    | Ok config -> config
    | Error e -> die (Syncbox_lib.Config.error_message e)
  in
  if
    not
      (Sys.file_exists config.data_dir && Sys.is_directory config.data_dir)
  then die (Printf.sprintf "data-dir does not exist or is not a directory: %s" config.data_dir);
  Printf.printf "syncbox-server: listening on 0.0.0.0:%d, data-dir=%s\n%!"
    config.port config.data_dir;
  Dream.run ~interface:"0.0.0.0" ~port:config.port
  @@ Dream.logger @@ Syncbox_lib.Server.router
