module Syncbox
  # One file's failure during push/pull/sync -- which key, what went wrong.
  # Collected alongside successes so one bad file doesn't abort the rest,
  # per SYNCBOX-SPEC.md's partial-failure requirement.
  Failure = Struct.new(:key, :message, keyword_init: true)
end
