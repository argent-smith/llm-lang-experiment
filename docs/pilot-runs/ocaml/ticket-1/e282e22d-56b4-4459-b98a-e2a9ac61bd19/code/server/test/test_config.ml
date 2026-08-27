open Syncbox_lib

let failures = ref 0

let check name condition =
  if condition then Printf.printf "PASS %s\n%!" name
  else begin
    Printf.printf "FAIL %s\n%!" name;
    incr failures
  end

let is_ok expected = function
  | Ok config -> config = expected
  | Error _ -> false

let is_error expected = function
  | Ok _ -> false
  | Error e -> e = expected

let () =
  check "missing data-dir with no env or args fails"
    (is_error Config.Missing_data_dir
       (Config.parse ~env_data_dir:None ~env_port:None []));

  check "data-dir via flag, default port"
    (is_ok
       { Config.data_dir = "/tmp/x"; port = 8080 }
       (Config.parse ~env_data_dir:None ~env_port:None
          [ "--data-dir"; "/tmp/x" ]));

  check "data-dir and port via flags"
    (is_ok
       { Config.data_dir = "/tmp/x"; port = 9090 }
       (Config.parse ~env_data_dir:None ~env_port:None
          [ "--data-dir"; "/tmp/x"; "--port"; "9090" ]));

  check "data-dir and port via env vars"
    (is_ok
       { Config.data_dir = "/env/dir"; port = 7000 }
       (Config.parse ~env_data_dir:(Some "/env/dir") ~env_port:(Some "7000")
          []));

  check "flags take precedence over env vars"
    (is_ok
       { Config.data_dir = "/flag/dir"; port = 9999 }
       (Config.parse ~env_data_dir:(Some "/env/dir") ~env_port:(Some "7000")
          [ "--data-dir"; "/flag/dir"; "--port"; "9999" ]));

  check "invalid --port flag value"
    (is_error (Config.Invalid_port "abc")
       (Config.parse ~env_data_dir:None ~env_port:None
          [ "--data-dir"; "/tmp/x"; "--port"; "abc" ]));

  check "invalid SYNCBOX_PORT env value"
    (is_error (Config.Invalid_port "xyz")
       (Config.parse ~env_data_dir:None ~env_port:(Some "xyz") []));

  check "unknown argument"
    (is_error
       (Config.Unknown_argument "--bogus")
       (Config.parse ~env_data_dir:None ~env_port:None [ "--bogus" ]));

  check "missing value for --data-dir"
    (is_error
       (Config.Missing_value "--data-dir")
       (Config.parse ~env_data_dir:None ~env_port:None [ "--data-dir" ]));

  check "missing value for --port"
    (is_error
       (Config.Missing_value "--port")
       (Config.parse ~env_data_dir:None ~env_port:None
          [ "--data-dir"; "/tmp/x"; "--port" ]));

  if !failures > 0 then begin
    Printf.printf "%d test(s) failed\n%!" !failures;
    exit 1
  end
  else Printf.printf "All config tests passed\n%!"
