(* Blob storage: blobs live on disk under [data_dir], keyed by their POSIX
   path relative to the store root (e.g. "docs/readme.txt" creates
   data_dir/docs/readme.txt, creating "docs" as needed).

   This covers the happy path (ticket 2) plus listing (ticket 3): no
   directory-traversal rejection of [key] and no atomic (write-then-rename)
   writes yet — both are scoped to later tickets. *)

(* [Dream.path] (the old way to read the wildcard-matched path segments) is
   deprecated and slated for removal, so the key is recovered from
   [Dream.target] instead, which is unaffected by routing and always holds
   the original request path. *)
let blob_key_segments request =
  let path, _query = Dream.split_target (Dream.target request) in
  match Dream.from_path path with
  | _blobs_segment :: rest -> rest
  | [] -> []

let blob_path data_dir segments = List.fold_left Filename.concat data_dir segments

let rec mkdir_p dir =
  if dir = "" || dir = "." || dir = "/" || Sys.file_exists dir then ()
  else begin
    mkdir_p (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let read_file path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path contents =
  mkdir_p (Filename.dirname path);
  let oc = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out oc)
    (fun () -> output_string oc contents)

let put_blob data_dir request =
  Lwt.bind (Dream.body request) (fun body ->
      let segments = blob_key_segments request in
      let key = String.concat "/" segments in
      let path = blob_path data_dir segments in
      write_file path body;
      let sha256 = Sha256.(to_hex (string body)) in
      let size = String.length body in
      let json =
        `Assoc
          [
            ("key", `String key);
            ("sha256", `String sha256);
            ("size", `Int size);
          ]
      in
      Dream.json ~status:`Created (Yojson.Safe.to_string json))

let get_blob data_dir request =
  let segments = blob_key_segments request in
  let path = blob_path data_dir segments in
  if Sys.file_exists path && not (Sys.is_directory path) then
    Dream.respond
      ~headers:[ ("Content-Type", "application/octet-stream") ]
      (read_file path)
  else Dream.respond ~status:`Not_Found ""

let iso8601_utc time =
  let tm = Unix.gmtime time in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec

(* Recursively collects every regular file under [data_dir], paired with its
   key segments relative to the store root. *)
let rec collect_files data_dir rel_segments acc =
  let dir = blob_path data_dir rel_segments in
  match Sys.readdir dir with
  | exception Sys_error _ -> acc
  | entries ->
      Array.sort compare entries;
      Array.fold_left
        (fun acc name ->
          let rel_segments = rel_segments @ [ name ] in
          let path = blob_path data_dir rel_segments in
          if Sys.is_directory path then
            collect_files data_dir rel_segments acc
          else (rel_segments, path) :: acc)
        acc entries

let blob_meta_json segments path =
  let key = String.concat "/" segments in
  let stat = Unix.stat path in
  let sha256 = Sha256.(to_hex (string (read_file path))) in
  `Assoc
    [
      ("key", `String key);
      ("size", `Int stat.Unix.st_size);
      ("sha256", `String sha256);
      ("modified_at", `String (iso8601_utc stat.Unix.st_mtime));
    ]

let list_blobs data_dir _request =
  let files = collect_files data_dir [] [] in
  let files =
    List.sort (fun (a, _) (b, _) -> compare a b) files
  in
  let json =
    `List (List.map (fun (segments, path) -> blob_meta_json segments path) files)
  in
  Dream.json (Yojson.Safe.to_string json)

let router data_dir =
  Dream.router
    [
      Dream.get "/healthz" (fun _ -> Dream.respond "ok");
      Dream.put "/blobs/**" (put_blob data_dir);
      Dream.get "/blobs" (list_blobs data_dir);
      Dream.get "/blobs/**" (get_blob data_dir);
    ]
