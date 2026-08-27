(* Blob storage: blobs live on disk under [data_dir], keyed by their POSIX
   path relative to the store root (e.g. "docs/readme.txt" creates
   data_dir/docs/readme.txt, creating "docs" as needed).

   This covers only the happy path (ticket 2): no directory-traversal
   rejection of [key] and no atomic (write-then-rename) writes yet — both
   are scoped to later tickets. *)

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

let router data_dir =
  Dream.router
    [
      Dream.get "/healthz" (fun _ -> Dream.respond "ok");
      Dream.put "/blobs/**" (put_blob data_dir);
      Dream.get "/blobs/**" (get_blob data_dir);
    ]
