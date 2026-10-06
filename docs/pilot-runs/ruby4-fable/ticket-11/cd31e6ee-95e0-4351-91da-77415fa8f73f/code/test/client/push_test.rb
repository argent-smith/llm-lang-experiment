# frozen_string_literal: true

require "test_helper"
require "digest"
require "fileutils"
require "stringio"

# Push against a scripted stand-in for the API: checks the plan (what gets
# uploaded, what is left alone) and the report, independent of HTTP.
class ClientPushTest < Minitest::Test
  include TestHelpers
  include ClientFailureHelpers

  Push = Syncbox::Client::Push
  Api = Syncbox::Client::Api

  class FakeApi
    attr_reader :puts, :list_calls, :closed

    # +fail_put+ maps key => exception (or a list of exceptions, one per
    # attempt) that PUT raises for that key instead of storing it.
    def initialize(remote, put_sha: nil, fail_put: {})
      @remote = remote
      @put_sha = put_sha
      @fail_put = fail_put.transform_values { |e| Array(e) }
      @puts = []
      @list_calls = 0
      @closed = false
    end

    def list
      @list_calls += 1
      @remote.map { |key, sha| Api::RemoteBlob.new(key: key, size: 1, sha256: sha, modified_at: "2026-01-01T00:00:00.000Z") }
    end

    def put(key, path)
      error = @fail_put[key]&.shift
      raise error if error

      content = File.binread(path)
      @puts << [key, content]
      Api::PutResult.new(key: key, size: content.bytesize, sha256: @put_sha || Digest::SHA256.hexdigest(content))
    end

    def close
      @closed = true
    end
  end

  def run_push(dir, api)
    out = StringIO.new
    err = StringIO.new
    summary = Push.new(dir: dir, api: api, out: out, err: err).call
    [summary, out.string, err.string]
  end

  def test_uploads_missing_and_changed_files_and_skips_identical_ones
    with_tmpdir do |dir|
      write(dir, "same.txt", "same")
      write(dir, "changed.txt", "v2")
      write(dir, "new/deep/file.bin", "\x00\x01".b)
      api = FakeApi.new({ "same.txt" => sha("same"), "changed.txt" => sha("v1"), "server-only.txt" => sha("s") })

      summary, out, err = run_push(dir, api)

      assert_equal [["changed.txt", "v2"], ["new/deep/file.bin", "\x00\x01".b]], api.puts
      assert_equal 1, api.list_calls, "the listing is fetched once, not per file"
      assert_equal 3, summary.scanned
      assert_equal 2, summary.uploaded
      assert_equal 1, summary.unchanged
      assert_equal <<~OUT, out
        uploaded changed.txt (changed, 2 bytes)
        uploaded new/deep/file.bin (new, 2 bytes)
        push done: 2 uploaded, 1 unchanged, 3 file(s) scanned
      OUT
      assert_equal "", err
      assert api.closed
    end
  end

  def test_second_push_of_an_unchanged_tree_uploads_nothing
    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "b/c", "C")
      api = FakeApi.new({ "a" => sha("A"), "b/c" => sha("C") })

      summary, out, = run_push(dir, api)
      assert_equal [], api.puts
      assert_equal "push done: 0 uploaded, 2 unchanged, 2 file(s) scanned\n", out
      assert_equal [2, 0, 2], [summary.scanned, summary.uploaded, summary.unchanged]
    end
  end

  def test_same_size_different_content_counts_as_changed
    with_tmpdir do |dir|
      write(dir, "f", "abc")
      api = FakeApi.new({ "f" => sha("abd") })
      run_push(dir, api)
      assert_equal [["f", "abc"]], api.puts
    end
  end

  def test_empty_directory_pushes_nothing_and_still_reports
    with_tmpdir do |dir|
      api = FakeApi.new({})
      summary, out, = run_push(dir, api)
      assert_equal [], api.puts
      assert_equal [0, 0, 0], [summary.scanned, summary.uploaded, summary.unchanged]
      assert_equal "push done: 0 uploaded, 0 unchanged, 0 file(s) scanned\n", out
    end
  end

  def test_skipped_entries_are_reported_on_stderr
    with_tmpdir do |dir|
      write(dir, "f", "x")
      File.symlink(File.join(dir, "f"), File.join(dir, "link"))
      api = FakeApi.new({})
      _, out, err = run_push(dir, api)
      assert_equal [["f", "x"]], api.puts
      assert_equal "syncbox: warning: skipping link: symbolic links are not uploaded\n", err
      refute_match(/link/, out)
    end
  end

  def test_sha_mismatch_from_the_server_is_a_failure_of_that_file
    with_tmpdir do |dir|
      write(dir, "f", "x")
      api = FakeApi.new({}, put_sha: "0" * 64)
      summary, out, err = run_push(dir, api)
      assert_equal [0, 1], [summary.uploaded, summary.failed]
      assert_equal "push done: 0 uploaded, 0 unchanged, 1 failed, 1 file(s) scanned\n", out
      assert_match(/\Asyncbox: failed f: server stored sha256 0{64}, expected #{sha('x')}/, err)
      assert_match(/^syncbox: push incomplete: 1 of 1 file\(s\) failed\nsyncbox:   f: server stored sha256/, err)
      assert api.closed, "the connection is closed even on failure"
    end
  end

  # The spec's partial-failure rule: one file failing (here the server
  # answers its PUT with a 5xx, then a transient network error on another)
  # does not stop the push; the rest is uploaded, the failed files are
  # listed on stderr at the end and the summary counts them.
  def test_a_failed_upload_does_not_stop_the_others_and_is_reported_at_the_end
    with_tmpdir do |dir|
      write(dir, "a.txt", "A")
      write(dir, "b.txt", "B")
      write(dir, "c.txt", "C")
      write(dir, "d.txt", "D")
      write(dir, "same.txt", "same")
      api = FakeApi.new({ "same.txt" => sha("same") },
                        fail_put: { "b.txt" => http_error(500, "PUT", "/blobs/b.txt", "disk on fire"),
                                    "c.txt" => Api::Unreachable.new("cannot reach server at http://s: connection reset by s:80 (PUT /blobs/c.txt)") })

      summary, out, err = run_push(dir, api)

      assert_equal [["a.txt", "A"], ["d.txt", "D"]], api.puts, "the files after the failed ones are still uploaded"
      assert_equal [5, 2, 1, 2], [summary.scanned, summary.uploaded, summary.unchanged, summary.failed]
      assert_equal <<~OUT, out
        uploaded a.txt (new, 1 bytes)
        uploaded d.txt (new, 1 bytes)
        push done: 2 uploaded, 1 unchanged, 2 failed, 5 file(s) scanned
      OUT
      assert_equal <<~ERR, err
        syncbox: failed b.txt: server answered 500 Internal Server Error to PUT /blobs/b.txt: disk on fire
        syncbox: failed c.txt: cannot reach server at http://s: connection reset by s:80 (PUT /blobs/c.txt)
        syncbox: push incomplete: 2 of 5 file(s) failed
        syncbox:   b.txt: server answered 500 Internal Server Error to PUT /blobs/b.txt: disk on fire
        syncbox:   c.txt: cannot reach server at http://s: connection reset by s:80 (PUT /blobs/c.txt)
      ERR
      assert api.closed
    end
  end

  # Two files in a row that cannot reach the server mean the server is gone:
  # the push stops instead of failing every remaining file one by one (each
  # of which could wait for the connect timeout), reports what it did not
  # attempt and raises, so the Runner exits with the "unreachable" status.
  def test_the_push_stops_when_the_server_stops_answering
    with_tmpdir do |dir|
      %w[a b c d e].each { |name| write(dir, "#{name}.txt", name) }
      gone = ->(key) { Api::Unreachable.new("cannot reach server at http://s: connection refused by s:80 (PUT /blobs/#{key})") }
      api = FakeApi.new({}, fail_put: { "b.txt" => gone.call("b.txt"), "c.txt" => gone.call("c.txt") })

      out = StringIO.new
      err = StringIO.new
      error = assert_raises(Syncbox::Client::Failures::ServerLost) { Push.new(dir: dir, api: api, out: out, err: err).call }
      assert_match(/\Aserver unreachable: cannot reach server at http:\/\/s: connection refused by s:80 \(PUT \/blobs\/c\.txt\); giving up after 2 consecutive requests failed \(2 file\(s\) not attempted/, error.message)
      assert_equal 2, error.not_attempted
      assert_equal [["a.txt", "a"]], api.puts, "nothing is attempted after the server is declared gone"
      assert_equal "uploaded a.txt (new, 1 bytes)\n", out.string, "no summary line for an aborted run"
      assert_equal <<~ERR, err.string
        syncbox: failed b.txt: cannot reach server at http://s: connection refused by s:80 (PUT /blobs/b.txt)
        syncbox: failed c.txt: cannot reach server at http://s: connection refused by s:80 (PUT /blobs/c.txt)
        syncbox: push aborted: 2 of 5 file(s) failed, 2 not attempted
        syncbox:   b.txt: cannot reach server at http://s: connection refused by s:80 (PUT /blobs/b.txt)
        syncbox:   c.txt: cannot reach server at http://s: connection refused by s:80 (PUT /blobs/c.txt)
      ERR
      assert api.closed
    end
  end

  def test_a_network_failure_followed_by_an_answer_from_the_server_does_not_count_as_a_lost_server
    with_tmpdir do |dir|
      %w[a b c d].each { |name| write(dir, "#{name}.txt", name) }
      gone = ->(key) { Api::Unreachable.new("cannot reach server at http://s: connection reset by s:80 (PUT /blobs/#{key})") }
      # b: network; c: the server answers (500) — the streak is broken; d: network again.
      api = FakeApi.new({}, fail_put: { "b.txt" => gone.call("b.txt"), "c.txt" => http_error(503, "PUT", "/blobs/c.txt", ""),
                                        "d.txt" => gone.call("d.txt") })
      summary, _, err = run_push(dir, api)
      assert_equal [1, 3], [summary.uploaded, summary.failed]
      assert_match(/push incomplete: 3 of 4 file\(s\) failed/, err)
    end
  end

  def test_a_file_that_cannot_be_read_is_a_failure_the_others_are_still_uploaded
    skip "root can read anything" if Process.uid.zero?

    with_tmpdir do |dir|
      write(dir, "ok", "x")
      write(dir, "sub/secret", "s")
      write(dir, "sub/fine", "f")
      File.chmod(0o000, File.join(dir, "sub/secret"))
      begin
        api = FakeApi.new({})
        summary, out, err = run_push(dir, api)
        assert_equal [["ok", "x"], ["sub/fine", "f"]], api.puts
        assert_equal [2, 2, 1], [summary.scanned, summary.uploaded, summary.failed]
        assert_equal "uploaded ok (new, 1 bytes)\nuploaded sub/fine (new, 1 bytes)\n" \
                     "push done: 2 uploaded, 0 unchanged, 1 failed, 2 file(s) scanned\n", out
        assert_equal <<~ERR, err
          syncbox: failed sub/secret: cannot read sub/secret: Permission denied @ rb_sysopen - #{dir}/sub/secret
          syncbox: push incomplete: 1 of 3 file(s) failed
          syncbox:   sub/secret: cannot read sub/secret: Permission denied @ rb_sysopen - #{dir}/sub/secret
        ERR
      ensure
        File.chmod(0o600, File.join(dir, "sub/secret"))
      end
    end
  end

  def test_a_file_name_that_cannot_be_a_key_is_a_failure_the_others_are_still_uploaded
    with_tmpdir do |dir|
      write(dir, "ok", "x")
      File.write(File.join(dir, "bad-\xFF".b), "y")
      api = FakeApi.new({})
      summary, _, err = run_push(dir, api)
      assert_equal [["ok", "x"]], api.puts
      assert_equal [1, 1, 1], [summary.scanned, summary.uploaded, summary.failed]
      assert_equal 1, api.list_calls
      assert_match(/\Asyncbox: failed "bad-\\xFF": file name is not valid UTF-8 and cannot be a key: "bad-\\xFF"\n/, err)
      assert_match(/push incomplete: 1 of 2 file\(s\) failed/, err)
    end
  end

  def test_a_file_that_vanishes_before_its_upload_is_a_failure_of_that_file
    with_tmpdir do |dir|
      write(dir, "a", "A")
      write(dir, "gone", "G")
      api = FakeApi.new({})
      api.define_singleton_method(:put) do |key, path|
        File.delete(path) if key == "gone" # the file disappears right before the request opens it
        super(key, path)
      end
      summary, _, err = run_push(dir, api)
      assert_equal [["a", "A"]], api.puts
      assert_equal [1, 1], [summary.uploaded, summary.failed]
      assert_match(/\Asyncbox: failed gone: .*No such file or directory/, err)
    end
  end

  private

  def sha(content)
    Digest::SHA256.hexdigest(content)
  end


  def write(dir, rel, content)
    path = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(path))
    File.binwrite(path, content)
  end
end
