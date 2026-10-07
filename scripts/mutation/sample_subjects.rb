# frozen_string_literal: true

# Случайная выборка субъектов mutant с фиксированным seed: ruby sample_subjects.rb <доля>
frac = ARGV.fetch(0, "1").to_f
subs = File.readlines(".mutant-subjects.txt").map(&:strip).reject(&:empty?)
subs.shuffle!(random: Random.new(42))
n = frac >= 1 ? subs.size : [1, (subs.size * frac).round].max
File.write(".mutant-subjects-sample.txt", subs.first(n).sort.join("\n") + "\n")
