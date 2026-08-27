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

let is_iso8601_utc s =
  try Scanf.sscanf s "%4d-%2d-%2dT%2d:%2d:%2dZ%!" (fun _ _ _ _ _ _ -> true)
  with _ -> false

let json_field name json =
  match json with
  | `Assoc fields -> ( match List.assoc_opt name fields with Some v -> v | None -> `Null)
  | _ -> `Null

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

  let list_resp =
    Dream.test router (Dream.request ~method_:`GET ~target:"/blobs" "")
  in
  check "GET /blobs returns 200" (Dream.status list_resp = `OK);
  let items =
    match Yojson.Safe.from_string (Lwt_main.run (Dream.body list_resp)) with
    | `List l -> l
    | _ -> []
  in
  check "GET /blobs lists exactly the stored blobs" (List.length items = 2);
  let expected =
    [ ("greeting.txt", overwritten); ("docs/readme.txt", nested_content) ]
  in
  List.iter
    (fun item ->
      let key = match json_field "key" item with `String s -> s | _ -> "" in
      match List.assoc_opt key expected with
      | None -> check (Printf.sprintf "GET /blobs: unexpected key %s" key) false
      | Some content ->
          let expected_size = String.length content in
          let expected_sha = Sha256.(to_hex (string content)) in
          check
            (Printf.sprintf "GET /blobs: %s has correct size" key)
            (json_field "size" item = `Int expected_size);
          check
            (Printf.sprintf "GET /blobs: %s has correct sha256" key)
            (json_field "sha256" item = `String expected_sha);
          check
            (Printf.sprintf "GET /blobs: %s has ISO 8601 UTC modified_at" key)
            (match json_field "modified_at" item with
            | `String s -> is_iso8601_utc s
            | _ -> false))
    items;

  let empty_router = Syncbox_lib.Server.router (make_temp_dir ()) in
  let empty_list_resp =
    Dream.test empty_router (Dream.request ~method_:`GET ~target:"/blobs" "")
  in
  check "GET /blobs on empty store returns 200"
    (Dream.status empty_list_resp = `OK);
  check "GET /blobs on empty store returns an empty array"
    (Lwt_main.run (Dream.body empty_list_resp) = "[]");

  if !failures > 0 then begin
    Printf.printf "%d test(s) failed\n%!" !failures;
    exit 1
  end
  else Printf.printf "All server tests passed\n%!"
