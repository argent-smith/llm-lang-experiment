let failures = ref 0

let check name condition =
  if condition then Printf.printf "PASS %s\n%!" name
  else begin
    Printf.printf "FAIL %s\n%!" name;
    incr failures
  end

let make_temp_dir () =
  let path = Filename.temp_file "syncbox_test_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path

let put_response_json key content =
  Yojson.Safe.to_string
    (`Assoc
      [
        ("key", `String key);
        ("sha256", `String Sha256.(to_hex (string content)));
        ("size", `Int (String.length content));
      ])

let () =
  let healthz =
    Dream.test (Syncbox_lib.Server.router (make_temp_dir ()))
      (Dream.request ~method_:`GET ~target:"/healthz" "")
  in
  check "GET /healthz returns 200" (Dream.status healthz = `OK);
  check "GET /healthz body is ok"
    (Lwt_main.run (Dream.body healthz) = "ok");

  let missing =
    Dream.test (Syncbox_lib.Server.router (make_temp_dir ()))
      (Dream.request ~method_:`GET ~target:"/does-not-exist" "")
  in
  check "GET on unknown route returns 404"
    (Dream.status missing = `Not_Found);

  let router = Syncbox_lib.Server.router (make_temp_dir ()) in

  let content = "hello syncbox" in
  let put_resp =
    Dream.test router
      (Dream.request ~method_:`PUT ~target:"/blobs/greeting.txt" content)
  in
  check "PUT /blobs/{key} returns 201" (Dream.status put_resp = `Created);
  check "PUT response body is the expected JSON"
    (Lwt_main.run (Dream.body put_resp)
    = put_response_json "greeting.txt" content);

  let get_resp =
    Dream.test router
      (Dream.request ~method_:`GET ~target:"/blobs/greeting.txt" "")
  in
  check "GET /blobs/{key} returns 200" (Dream.status get_resp = `OK);
  check "GET body matches uploaded content"
    (Lwt_main.run (Dream.body get_resp) = content);

  let nested_content = "nested contents" in
  let nested_put =
    Dream.test router
      (Dream.request ~method_:`PUT ~target:"/blobs/docs/readme.txt"
         nested_content)
  in
  check "PUT with nested key returns 201"
    (Dream.status nested_put = `Created);
  check "PUT response body uses the full nested key"
    (Lwt_main.run (Dream.body nested_put)
    = put_response_json "docs/readme.txt" nested_content);
  let nested_get =
    Dream.test router
      (Dream.request ~method_:`GET ~target:"/blobs/docs/readme.txt" "")
  in
  check "GET nested key returns 200" (Dream.status nested_get = `OK);
  check "GET nested key body matches upload"
    (Lwt_main.run (Dream.body nested_get) = nested_content);

  let missing_blob =
    Dream.test router
      (Dream.request ~method_:`GET ~target:"/blobs/does-not-exist.txt" "")
  in
  check "GET on missing key returns 404"
    (Dream.status missing_blob = `Not_Found);

  let overwritten = "new content, replacing the old" in
  let overwrite_put =
    Dream.test router
      (Dream.request ~method_:`PUT ~target:"/blobs/greeting.txt" overwritten)
  in
  check "PUT on existing key returns 201"
    (Dream.status overwrite_put = `Created);
  let overwrite_get =
    Dream.test router
      (Dream.request ~method_:`GET ~target:"/blobs/greeting.txt" "")
  in
  check "GET after overwrite returns the new content"
    (Lwt_main.run (Dream.body overwrite_get) = overwritten);

  if !failures > 0 then begin
    Printf.printf "%d test(s) failed\n%!" !failures;
    exit 1
  end
  else Printf.printf "All server tests passed\n%!"
