let failures = ref 0

let check name condition =
  if condition then Printf.printf "PASS %s\n%!" name
  else begin
    Printf.printf "FAIL %s\n%!" name;
    incr failures
  end

let () =
  let healthz =
    Dream.test Syncbox_lib.Server.router
      (Dream.request ~method_:`GET ~target:"/healthz" "")
  in
  check "GET /healthz returns 200" (Dream.status healthz = `OK);
  check "GET /healthz body is ok"
    (Lwt_main.run (Dream.body healthz) = "ok");

  let missing =
    Dream.test Syncbox_lib.Server.router
      (Dream.request ~method_:`GET ~target:"/does-not-exist" "")
  in
  check "GET on unknown route returns 404"
    (Dream.status missing = `Not_Found);

  if !failures > 0 then begin
    Printf.printf "%d test(s) failed\n%!" !failures;
    exit 1
  end
  else Printf.printf "All server tests passed\n%!"
