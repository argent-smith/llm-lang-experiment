module Syncbox
  # Shared "summary report" for the partial-failure case (see "Коды возврата
  # и ошибки" in SYNCBOX-SPEC.md): push/pull/sync/status all collect
  # {key:, message:} pairs while processing files and print them together at
  # the end, rather than interleaving them with progress output.
  module FailureReport
    module_function

    def print(failed, err)
      return if failed.empty?

      err.puts "syncbox: #{failed.size} file(s) failed:"
      failed.each { |f| err.puts "  #{f[:key]}: #{f[:message]}" }
    end
  end
end
