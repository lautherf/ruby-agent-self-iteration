# frozen_string_literal: true

# RA 记分卡 —— 在受控（train/holdout 隔离 + scratch lessons）条件下跑一次成长闭环，
# 记录可比较的指标 JSON，供后续每次"升级"对照。不改仓库里的 lessons.rb。
#
# 用法：
#   AGNES_API_KEY=sk-... ruby -Ilib examples/ra_scorecard.rb \
#     /tmp/opencode/bbh/logical_deduction_five_objects.json \
#     --gradebook examples/gradebook/bbh_five_merged_20260916.json \
#     [--tag baseline] [--rounds 3] [--per-round 3] [--holdout 5] [--no-spec]
#
# 输出：examples/scorecard/<tag>_<UTC>.json + 终端摘要。

require 'json'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'time'

ROOT = File.expand_path('..', __dir__)
GROW = File.join(__dir__, 'bbh_grow.rb')
LESSONS = File.join(__dir__, 'lessons.rb')
SCORECARD_DIR = File.join(__dir__, 'scorecard')

def run_grow(data, gradebook, scratch_lessons, rounds, per_round, holdout)
  args = [RbConfig.ruby, '-Ilib', GROW, data,
          '--gradebook', gradebook, '--lessons', scratch_lessons,
          '--rounds', rounds.to_s, '--per-round', per_round.to_s, '--holdout', holdout.to_s]
  out, err, status = Open3.capture3(*args, chdir: ROOT)
  warn err unless err.to_s.strip.empty?
  abort "bbh_grow 退出码 #{status.exitstatus}" unless status.success?

  line = out.lines.find { |l| l.start_with?('SCORECARD ') }
  abort '未找到 SCORECARD 行' unless line

  [out, JSON.parse(line.sub('SCORECARD ', ''))]
end

def spec_status
  out, = Open3.capture3(RbConfig.ruby, '-Ilib', '-Ispec', '-e',
                        "Dir['spec/*_spec.rb'].each { |f| require File.expand_path(f) }", chdir: ROOT)
  summary = out.lines.find { |l| l =~ /runs?,.*assertions?/ }&.strip
  m = out.match(/(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors/)
  {
    green: m && m[3] == '0' && m[4] == '0',
    runs: m && m[1].to_i, failures: m && m[3].to_i, errors: m && m[4].to_i,
    summary: summary
  }
end

def main
  data = ARGV.find { |a| !a.start_with?('--') }
  gradebook = (i = ARGV.index('--gradebook')) ? ARGV[i + 1] : abort('需 --gradebook')
  tag = (t = ARGV.index('--tag')) ? ARGV[t + 1] : 'run'
  rounds = (j = ARGV.index('--rounds')) ? ARGV[j + 1].to_i : 3
  per_round = (k = ARGV.index('--per-round')) ? ARGV[k + 1].to_i : 3
  holdout = (h = ARGV.index('--holdout')) ? ARGV[h + 1].to_i : 5
  repeat = (n = ARGV.index('--repeat')) ? ARGV[n + 1].to_i : 1
  with_spec = !ARGV.include?('--no-spec')

  abort "缺数据文件" if data.nil? || !File.exist?(data)
  FileUtils.mkdir_p(SCORECARD_DIR)

  puts "═══ RA 记分卡 [#{tag}]：rounds=#{rounds} per_round=#{per_round} " \
       "holdout=#{holdout} repeat=#{repeat} ═══"
  cards = []
  repeat.times do |r|
    Dir.mktmpdir('ra-scorecard') do |dir|
      scratch = File.join(dir, 'lessons.rb')
      FileUtils.cp(LESSONS, scratch)
      puts "\n──── repeat #{r + 1}/#{repeat} ────"
      out, card = run_grow(data, gradebook, scratch, rounds, per_round, holdout)
      print out unless repeat == 1
      cards << card
    end
  end

  base_list = cards.map { |c| c['holdout_baseline'] }
  final_list = cards.map { |c| c['holdout_final'] }
  hsize = cards.first['holdout_idx'].size
  avg = ->(xs) { (xs.sum.to_f / xs.size).round(2) }
  # 每轮 holdout 的跨 repeat 均值
  holdout_avg = (0..rounds).map do |r|
    vals = cards.map { |c| c['holdout_curve'][r][1] }
    [r, avg.call(vals), vals.min, vals.max]
  end
  train_avg = (0...rounds).map do |r|
    vals = cards.map { |c| c['train_curve'][r][1] }
    [r + 1, avg.call(vals)]
  end

  card = cards.first.merge(
    'tag' => tag, 'timestamp' => Time.now.utc.iso8601, 'repeat' => repeat,
    'runs' => cards,
    'holdout_baseline_mean' => avg.call(base_list), 'holdout_final_mean' => avg.call(final_list),
    'holdout_delta_mean' => (avg.call(final_list) - avg.call(base_list)).round(2),
    'holdout_baseline_range' => [base_list.min, base_list.max],
    'holdout_final_range' => [final_list.min, final_list.max],
    'holdout_curve_mean' => holdout_avg, 'train_curve_mean' => train_avg,
    'lessons_added' => cards.flat_map { |c| c['lessons_added'] }.uniq,
    'spec' => with_spec ? spec_status : { skipped: true }
  )

  file = File.join(SCORECARD_DIR, "#{tag}_#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}.json")
  File.write(file, JSON.pretty_generate(card))

  puts "\n═══ 记分（#{repeat} 次均值）═══"
  puts format('  holdout: 基线 %.2f/%d → 终值 %.2f/%d（Δ %+.2f）  单次范围 基线%s 终值%s',
              card['holdout_baseline_mean'], hsize, card['holdout_final_mean'], hsize,
              card['holdout_delta_mean'],
              card['holdout_baseline_range'].inspect, card['holdout_final_range'].inspect)
  puts "  holdout 曲线均值: #{holdout_avg.map { |r, v, _mn, _mx| "R#{r}=#{v}" }.join(' ')}"
  puts "  train  曲线均值: #{train_avg.map { |r, v| "R#{r}=#{v}" }.join(' ')}"
  puts "  lessons: #{cards.last['lessons_total']} 条（新增 #{card['lessons_added'].size}）"
  puts "  spec:    #{card['spec'][:green] ? '全绿' : '异常'} #{card['spec'][:summary]}" if with_spec
  puts "  存档:    #{file}"
end

main if $PROGRAM_NAME == __FILE__
