# frozen_string_literal: true

require "test_helper"
require "net/http"
require "socket"
require "timeout"
require "open3"
require "time"
require "digest"

# Boots the real executable (bin/syncbox-server) as a child process and talks
# to it over HTTP — the same surface the external acceptance checks use.
class ServerProcessTest < Minitest::Test
  include TestHelpers
  include ServerProcessHelpers

  def test_serves_healthz_via_flags
    with_tmpdir do |dir|
      data_dir = File.join(dir, "store")
      port = free_port

      with_server(%W[--data-dir #{data_dir} --port #{port}]) do
        response = wait_for_healthz(port)
        assert_equal "200", response.code
        assert_equal({ "status" => "ok" }, JSON.parse(response.body))
        assert File.directory?(data_dir), "data dir should be created on boot"
      end
    end
  end

  def test_serves_healthz_via_environment_variables
    with_tmpdir do |dir|
      port = free_port
      env = { "SYNCBOX_DATA_DIR" => dir, "SYNCBOX_PORT" => port.to_s }

      with_server([], env: env) do
        assert_equal "200", wait_for_healthz(port).code
      end
    end
  end

  def test_shuts_down_cleanly_on_sigterm
    with_tmpdir do |dir|
      port = free_port
      pid = spawn_server(%W[--data-dir #{dir} --port #{port}])
      wait_for_healthz(port)

      Process.kill("TERM", pid)
      _, status = Timeout.timeout(BOOT_TIMEOUT) { Process.wait2(pid) }
      assert status.exited?, "server should exit after SIGTERM (status: #{status.inspect})"
      assert_equal 0, status.exitstatus
    end
  end

  # Contract check through the real HTTP stack: every operation on /blobs and
  # /blobs/{key} answers with a status listed for it in syncbox-openapi.yaml,
  # including for garbage keys, and the server never answers 5xx.
  def test_blob_endpoints_answer_within_the_openapi_contract
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)

        Net::HTTP.start("127.0.0.1", port) do |http|
          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal [], JSON.parse(response.body)

          put = Net::HTTP::Put.new("/blobs/0", "content-type" => "application/octet-stream")
          put.body = "zero"
          response = http.request(put)
          assert_equal "201", response.code
          assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest("zero"), "size" => 4 },
                       JSON.parse(response.body))

          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal ["0"], JSON.parse(response.body).map { |m| m["key"] }

          response = http.get("/blobs/0")
          assert_equal "200", response.code
          assert_equal "zero", response.body

          assert_equal "204", http.delete("/blobs/0").code
          assert_equal "404", http.get("/blobs/0").code
        end

        # Raw sockets so that no client-side URI normalisation hides garbage.
        raw_paths = ["/blobs/", "/blobs//", "/blobs/../x", "/blobs/%2e%2e/x", "/blobs/..%2Fx", "/blobs/%00",
                     "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%2F", "/blobs/#{'x' * 300}", "/blobs/a/./b"]
        raw_paths.each do |path|
          status = raw_status(port, "PUT", path, body: "x")
          assert_equal 400, status, "PUT #{path}"
          status = raw_status(port, "GET", path)
          assert_includes [400, 404], status, "GET #{path}"
          status = raw_status(port, "DELETE", path)
          assert_includes [400, 404], status, "DELETE #{path}"
        end
        # Malformed percent escapes: Puma may reject them itself; either way the
        # answer must come from the schema (201 or 400 for PUT) and not be 5xx.
        ["/blobs/50%zz", "/blobs/%", "/blobs/%2", "/blobs/a%G1"].each do |path|
          assert_includes [201, 400], raw_status(port, "PUT", path, body: "x"), "PUT #{path}"
          assert_includes [200, 400, 404], raw_status(port, "GET", path), "GET #{path}"
        end

        assert_equal 200, raw_status(port, "GET", "/blobs")
        assert_equal 200, raw_status(port, "GET", "/healthz"), "server still healthy after garbage"
      end
    end
  end

  # DELETE /blobs/{key} through the real HTTP stack (ticket 4): 204 with an
  # empty body, the blob vanishes from GET and from the listing, repeated or
  # unknown keys answer 404, and the server stays healthy throughout.
  def test_delete_blob_over_http
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)

        Net::HTTP.start("127.0.0.1", port) do |http|
          { "docs/readme.txt" => "hello", "docs/img/logo.png" => "\x89PNG".b, "sp%20ace/%C3%BC.txt" => "" }
            .each do |raw_key, body|
            put = Net::HTTP::Put.new("/blobs/#{raw_key}", "content-type" => "application/octet-stream")
            put.body = body
            assert_equal "201", http.request(put).code, raw_key
          end

          response = http.delete("/blobs/docs/readme.txt")
          assert_equal "204", response.code
          assert_nil response.body
          assert_nil response["content-length"]
          assert_nil response["content-type"]

          assert_equal "404", http.get("/blobs/docs/readme.txt").code
          assert_equal "404", http.delete("/blobs/docs/readme.txt").code
          assert_equal "404", http.delete("/blobs/never-existed").code
          assert_equal "404", http.delete("/blobs/docs").code, "a directory is not a blob"

          list = JSON.parse(http.get("/blobs").body)
          assert_equal ["docs/img/logo.png", "sp ace/ü.txt"], list.map { |m| m["key"] }
          assert_equal "\x89PNG".b, http.get("/blobs/docs/img/logo.png").body.b

          assert_equal "204", http.delete("/blobs/sp%20ace/%C3%BC.txt").code
          assert_equal "204", http.delete("/blobs/docs/img/logo.png").code
          assert_equal [], JSON.parse(http.get("/blobs").body)
          refute File.exist?(File.join(dir, "blobs", "docs")), "emptied directories are pruned"
          assert File.directory?(File.join(dir, "blobs")), "storage root stays"

          put = Net::HTTP::Put.new("/blobs/docs", "content-type" => "application/octet-stream")
          put.body = "reused as a file"
          assert_equal "201", http.request(put).code
          assert_equal "reused as a file", http.get("/blobs/docs").body
        end

        # Over a raw socket the 204 must carry no body at all, so a client
        # reading to EOF sees headers only.
        Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
          sock.write("DELETE /blobs/docs HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
          raw = Timeout.timeout(5) { sock.read }
          head, body = raw.split("\r\n\r\n", 2)
          assert_match(%r{\AHTTP/1\.1 204 }, head)
          assert_equal "", body.to_s
        end

        assert_equal 200, raw_status(port, "GET", "/healthz")
      end
    end
  end

  # GET /blobs through the real HTTP stack: nested and percent-encoded keys
  # come back as POSIX paths, and every element conforms to BlobMeta in
  # syncbox-openapi.yaml.
  def test_list_blobs_over_http_conforms_to_blob_meta_schema
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)

        Net::HTTP.start("127.0.0.1", port) do |http|
          { "docs/readme.txt" => "hello", "docs/img/logo.png" => "\x89PNG".b, "sp%20ace/%C3%BC.txt" => "" }
            .each do |raw_key, body|
            put = Net::HTTP::Put.new("/blobs/#{raw_key}", "content-type" => "application/octet-stream")
            put.body = body
            assert_equal "201", http.request(put).code, raw_key
          end

          response = http.get("/blobs")
          assert_equal "200", response.code
          assert_equal "application/json", response["content-type"]

          list = JSON.parse(response.body)
          assert_equal ["docs/img/logo.png", "docs/readme.txt", "sp ace/ü.txt"], list.map { |m| m["key"] }
          list.each do |meta|
            assert_equal %w[key modified_at sha256 size], meta.keys.sort, meta.inspect
            assert_kind_of Integer, meta["size"]
            assert_operator meta["size"], :>=, 0
            assert_match(/\A[0-9a-f]{64}\z/, meta["sha256"])
            assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(\.\d+)?Z\z/, meta["modified_at"])
            assert_in_delta Time.now.to_f, Time.iso8601(meta["modified_at"]).to_f, 60, meta.inspect
          end

          readme = list.find { |m| m["key"] == "docs/readme.txt" }
          assert_equal({ "size" => 5, "sha256" => Digest::SHA256.hexdigest("hello") }, readme.slice("size", "sha256"))
          empty = list.find { |m| m["key"] == "sp ace/ü.txt" }
          assert_equal({ "size" => 0, "sha256" => Digest::SHA256.hexdigest("") }, empty.slice("size", "sha256"))
        end
      end
    end
  end

  def test_missing_data_dir_fails_with_usage_error
    stdout, stderr, status = run_cli("--port", free_port.to_s)
    assert_equal 2, status.exitstatus, "stdout: #{stdout}\nstderr: #{stderr}"
    assert_match(/--data-dir is required/, stderr)
    assert_match(/Usage:/, stderr)
  end

  def test_invalid_port_fails_with_usage_error
    with_tmpdir do |dir|
      _, stderr, status = run_cli("--data-dir", dir, "--port", "abc")
      assert_equal 2, status.exitstatus
      assert_match(/invalid port/, stderr)
    end
  end

  def test_help_prints_usage_and_exits_zero
    stdout, _, status = run_cli("--help")
    assert_equal 0, status.exitstatus
    assert_match(/Usage: syncbox-server --data-dir <path> \[--port <n>\]/, stdout)
  end

  def test_unwritable_data_dir_fails
    skip "root can write anywhere" if Process.uid.zero?

    with_tmpdir do |dir|
      File.chmod(0o500, dir)
      begin
        _, stderr, status = run_cli("--data-dir", File.join(dir, "store"), "--port", free_port.to_s)
        assert_equal 1, status.exitstatus
        assert_match(/Permission denied/, stderr)
      ensure
        File.chmod(0o700, dir)
      end
    end
  end

  # Directory traversal protection through the real HTTP stack (ticket 5):
  # paths sent byte-for-byte over a raw socket (so no client normalisation
  # hides anything) answer 400 on PUT, GET and DELETE alike, never leak or
  # touch a file outside the storage root, and leave the server healthy.
  def test_traversal_keys_are_400_over_http_and_cannot_reach_outside_the_root
    with_tmpdir do |dir|
      File.write(File.join(dir, "secret"), "s3cret")
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)
        FileUtils.mkdir_p(File.join(dir, "blobs"))
        File.symlink(File.join(dir, "secret"), File.join(dir, "blobs", "flink"))
        File.symlink("/", File.join(dir, "blobs", "rootlink"))

        traversal = [
          "/blobs/..", "/blobs/../secret", "/blobs/a/../../secret", "/blobs/%2e%2e/secret", "/blobs/%2E%2E/secret",
          "/blobs/..%2Fsecret", "/blobs/%2e%2e%2fsecret", "/blobs/.%2e/secret", "/blobs/a%2F..%2F..%2Fsecret",
          "/blobs/#{'../' * 10}etc/passwd", "/blobs/#{'%2e%2e%2f' * 10}etc%2fpasswd",
          "/blobs//secret", "/blobs/%2Fsecret", "/blobs/%2fetc%2fpasswd", "/blobs//etc/passwd",
          "/blobs/%00", "/blobs/a%00b", "/blobs/%ED%A0%80", "/blobs/%FF", "/blobs/%C0%AE%C0%AE/secret",
          "/blobs/#{'x' * 256}", "/blobs/flink", "/blobs/rootlink/etc/passwd", "/blobs/./secret", "/blobs/a/"
        ]
        traversal.each do |path|
          %w[PUT GET DELETE].each do |method|
            status, body = raw_request(port, method, path, body: method == "PUT" ? "planted" : "")
            assert_equal 400, status, "#{method} #{path}"
            refute_includes body, "s3cret", "#{method} #{path} leaked a file outside the root"
          end
        end

        # Decoded exactly once: "%252e%252e" is the literal directory "%2e%2e".
        status, body = raw_request(port, "PUT", "/blobs/%252e%252e/x", body: "literal")
        assert_equal 201, status, body
        assert_equal [200, "literal"], raw_request(port, "GET", "/blobs/%252e%252e/x")
        assert_equal 204, raw_request(port, "DELETE", "/blobs/%252e%252e/x").first

        assert_equal "s3cret", File.read(File.join(dir, "secret")), "file outside the root must be untouched"
        assert_equal %w[blobs secret tmp], Dir.children(dir).sort
        assert_equal %w[flink rootlink], Dir.children(File.join(dir, "blobs")).sort
        assert_equal [200, "[]"], raw_request(port, "GET", "/blobs")
        assert_equal 200, raw_status(port, "GET", "/healthz"), "server still healthy after traversal attempts"
      end
    end
  end

  # --- atomic writes under concurrent PUT (ticket 6) ------------------------

  # Writers hammer one key through the real HTTP stack while readers fetch it
  # and poll the listing: every GET body must be one complete version (never
  # a mix or a truncation), every listing entry must be self-consistent, and
  # nothing but the blob itself may remain on disk afterwards.
  def test_concurrent_puts_over_http_never_expose_a_partial_version
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)
        versions = Array.new(6) { |i| ("a".ord + i).chr * (200_000 + i * 1_000) }
        sha_by_size = versions.to_h { |v| [v.bytesize, Digest::SHA256.hexdigest(v)] }
        Net::HTTP.start("127.0.0.1", port) { |http| assert_equal "201", http.request(put_request("same", versions.first)).code }

        done = false
        failures = Queue.new
        writers = versions.map do |data|
          Thread.new do
            Net::HTTP.start("127.0.0.1", port) do |http|
              6.times do
                response = http.request(put_request("same", data))
                failures << "PUT answered #{response.code}" unless response.code == "201"
                failures << "PUT echoed wrong sha256" unless JSON.parse(response.body)["sha256"] == sha_by_size[data.bytesize]
              end
            end
          end
        end
        readers = Array.new(4) do
          Thread.new do
            reads = 0
            Net::HTTP.start("127.0.0.1", port) do |http|
              until done
                response = http.get("/blobs/same")
                reads += 1
                body = response.body.to_s.b
                next if response.code == "200" && versions.include?(body)

                failures << "GET #{response.code}: #{body.bytesize} bytes, chars #{body.chars.uniq.inspect}"
              end
            end
            reads
          end
        end
        lister = Thread.new do
          lists = 0
          Net::HTTP.start("127.0.0.1", port) do |http|
            until done
              response = http.get("/blobs")
              lists += 1
              failures << "list answered #{response.code}" unless response.code == "200"
              JSON.parse(response.body).each do |meta|
                next if meta["key"] == "same" && sha_by_size[meta["size"]] == meta["sha256"]

                failures << "inconsistent listing entry #{meta.inspect}"
              end
            end
          end
          lists
        end

        writers.each(&:join)
        done = true
        total_reads = readers.sum(&:value)
        total_lists = lister.value

        assert_empty failures.size.times.map { failures.pop }
        assert_operator total_reads, :>, 0
        assert_operator total_lists, :>, 0
        Net::HTTP.start("127.0.0.1", port) do |http|
          assert_includes versions, http.get("/blobs/same").body.b
          assert_equal ["same"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
        end
        assert_equal ["same"], Dir.children(File.join(dir, "blobs"))
        assert_equal [], Dir.children(File.join(dir, "tmp")), "no staging files may survive the requests"
        assert_equal 200, raw_status(port, "GET", "/healthz")
      end
    end
  end

  # A client that announces a body and disconnects before sending all of it
  # (plain Content-Length and chunked alike) must neither replace the stored
  # version with a truncated one nor leave a staging file behind.
  def test_aborted_put_leaves_no_blob_and_no_staging_file
    with_tmpdir do |dir|
      port = free_port

      with_server(%W[--data-dir #{dir} --port #{port}]) do
        wait_for_healthz(port)
        Net::HTTP.start("127.0.0.1", port) { |http| assert_equal "201", http.request(put_request("k", "intact")).code }

        Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
          sock.write("PUT /blobs/k HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n#{'x' * 1000}")
          sock.flush
        end
        Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
          sock.write("PUT /blobs/fresh HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\n#{'y' * 1000}")
          sock.flush
        end
        Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
          sock.write("PUT /blobs/chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" \
                     "400\r\n#{'z' * 1024}\r\n400\r\n#{'z' * 10}")
          sock.flush
        end

        # Puma notices the disconnect asynchronously; give it a moment.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep 0.1 while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline &&
                        !Dir.children(File.join(dir, "tmp")).empty?

        assert_equal [], Dir.children(File.join(dir, "tmp")), "an aborted upload must not leave a staging file"
        Net::HTTP.start("127.0.0.1", port) do |http|
          assert_equal "intact", http.get("/blobs/k").body
          assert_equal "404", http.get("/blobs/fresh").code
          assert_equal "404", http.get("/blobs/chunked").code
          assert_equal ["k"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
        end
        assert_equal ["k"], Dir.children(File.join(dir, "blobs"))
        assert_equal 200, raw_status(port, "GET", "/healthz"), "server still healthy after aborted uploads"
      end
    end
  end

  # A process that died mid-write leaves its staging file behind; the next
  # boot removes it, says so on stderr, and leaves everything else alone.
  def test_boot_sweeps_stale_staging_files
    with_tmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "tmp"))
      File.write(File.join(dir, "tmp", "put-#{'c' * 32}"), "half-written by a crashed process")
      File.write(File.join(dir, "tmp", "not-ours"), "keep")
      port = free_port
      stderr_path = File.join(dir, "stderr.log")

      pid = Process.spawn(clean_env, SERVER_BIN, "--data-dir", dir, "--port", port.to_s,
                          out: File::NULL, err: stderr_path)
      begin
        wait_for_healthz(port)
        assert_equal ["not-ours"], Dir.children(File.join(dir, "tmp"))
        assert_match(/removed 1 stale staging file/, File.read(stderr_path))
        assert_equal 201, raw_status(port, "PUT", "/blobs/k", body: "v")
        assert_equal ["not-ours"], Dir.children(File.join(dir, "tmp"))
      ensure
        Process.kill("TERM", pid)
        Timeout.timeout(BOOT_TIMEOUT) { Process.wait(pid) }
      end
    end
  end

  private

  def put_request(raw_key, body)
    request = Net::HTTP::Put.new("/blobs/#{raw_key}", "content-type" => "application/octet-stream")
    request.body = body
    request
  end

  # Runs the executable to completion with a timeout, so that a server which
  # unexpectedly starts listening cannot hang the whole suite.
  def run_cli(*args, env: {})
    Open3.popen3(clean_env(env), SERVER_BIN, *args) do |stdin, stdout, stderr, wait_thr|
      stdin.close
      out_reader = Thread.new { stdout.read }
      err_reader = Thread.new { stderr.read }
      unless wait_thr.join(BOOT_TIMEOUT)
        Process.kill("KILL", wait_thr.pid)
        flunk "#{SERVER_BIN} #{args.join(' ')} did not exit within #{BOOT_TIMEOUT}s"
      end
      [out_reader.value, err_reader.value, wait_thr.value]
    end
  end

  # Sends one HTTP/1.1 request with the path exactly as given and returns the
  # status code.
  def raw_status(port, method, path, body: "")
    Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
      sock.write("#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" \
                 "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      status_line = Timeout.timeout(5) { sock.gets }
      flunk "no response for #{method} #{path}" if status_line.nil?
      Integer(status_line.split(" ")[1], 10)
    end
  end

  # Like raw_status, but also returns the response body (read to EOF).
  def raw_request(port, method, path, body: "")
    Socket.tcp("127.0.0.1", port, connect_timeout: 2) do |sock|
      sock.write("#{method} #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n" \
                 "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      raw = Timeout.timeout(5) { sock.read }
      flunk "no response for #{method} #{path}" if raw.nil? || raw.empty?
      head, response_body = raw.split("\r\n\r\n", 2)
      [Integer(head.lines.first.split(" ")[1], 10), response_body.to_s]
    end
  end
end
