$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'json'
require 'time'

# 转移测验（Transfer Test）—— 考"会"，不考"背题"。
#
# 动机（外人反思 #5）：此前所有考核都是"原题复用教学卷"，
# 无法区分「学会了」与「背下了」。转移测验把每门课的能力
# 移到**教学卷之外的新题面**上复验：
#   · 换参数（gcd 交换/大数）
#   · 换规模（组合数 C(50,5)）
#   · 换维度形态（长方形矩阵/三维均匀分布）
#   · 换样本点（随机真值而不是全表）
#   · 换边界（新字/新标点）
# 判分与 golden/消融同款：机械 oracle，不许人眼掺水。
# 成绩存档 examples/gradebook/transfer_<ts>.json。
#
# 用法：
#   ruby -Ilib examples/transfer_test.rb --dry   # 打印题面不烧 LLM
#   ruby -Ilib examples/transfer_test.rb         # 全量配置 8 题
ROOT = File.expand_path('..', __dir__)

# { name:, course:, variant_of:, q:, oracle: }
TRANSFER = [
  {
    name: 'gcd-swap',
    course: '小学数学',
    variant_of: 'gcd 考过 gcd(12,18)，现在交换两个参数',
    q: '只输出一个数字：gcd(18, 12) 等于多少？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(6)(?:[^\d]|$)/) }
  },
  {
    name: 'gcd-large',
    course: '小学数学',
    variant_of: 'gcd 大数（防背答案）',
    q: '只输出一个数字：gcd(1071, 462) 等于多少？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(21)(?:[^\d]|$)/) }
  },
  {
    name: 'combination-big',
    course: '初中数学',
    variant_of: '组合数从 C(5,2) 抬高到 C(50,5)',
    q: '只输出一个数字：C(50,5) 等于多少？',
    oracle: ->(a) { a.include?('2118760') }
  },
  {
    name: 'matmul-rect',
    course: '大学·LLM基础',
    variant_of: '矩阵乘法换矩形（2×3·3×2 而非原 2×2）',
    q: '只输出结果矩阵：[[1,2,3],[4,5,6]] 乘以 [[1,2],[3,4],[5,6]] 等于？（输出形如 [[22,28],[49,64]]）',
    oracle: ->(a) { a.include?('22') && a.include?('28') && a.include?('49') && a.include?('64') }
  },
  {
    name: 'transpose-rect',
    course: '大学·LLM基础',
    variant_of: '转置换长方形 3×2（原考 2×3）',
    q: '只输出转置结果：transpose([[1,2],[3,4],[5,6]]) 等于？（输出形如 [[1,3,5],[2,4,6]]）',
    oracle: ->(a) { a.include?('1') && a.include?('3') && a.include?('5') && a.include?('2') && a.include?('4') && a.include?('6') }
  },
  {
    name: 'entropy-uniform4',
    course: '大学·LLM基础',
    variant_of: '熵从 0.5/0.5 二项改 4 均匀（答案恰为 log2(4)=2）',
    q: '只输出一个数字：熵 entropy([0.25,0.25,0.25,0.25]) 等于多少？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(2(?:\.0)?)(?:[^\d]|$)/) }
  },
  {
    name: 'law-random-point',
    course: '逻辑学',
    variant_of: '定律不再考全表，改考随机抽样点是否恒成立',
    q: "只输出 true 或 false：对指派 p=true,q=false，逆否等价律 law_of_contrapositive(p,q) 是否成立？",
    oracle: ->(a) { a.match?(/true/i) && !a.match?(/false/i) }
  },
  {
    name: 'tone-new-word',
    course: '小学语文',
    variant_of: '换一个没教过的字考声调（不是背 hǎo）',
    q: "只输出一个数字：拼音 'lǜ' 的声调是几声（1-4声）？",
    oracle: ->(a) { a.match?(/(?:^|[^\d])(4)(?:[^\d]|$)/) }
  }
].freeze

def build_full_agent
  hub = RubyAgent::DocHub.new
  knowledge = RubyAgent::Knowledge.new(File.join(ROOT, 'examples', 'lessons.rb'))
  hub.mount(RubyAgent::DocPlugin.new('ra', File.join(ROOT, 'plugins', 'ra.rb')).load!)
  hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)
  llm = RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
  agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge,
                                   max_steps: 8, writable_plugins: ['ra'], mode: :exam)
  agent
end

def run_question(t)
  3.times do |attempt|
    answer = begin
      build_full_agent.run(t[:q]).to_s
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 60]}"
    end
    answer = answer.sub(/Final Answer:?\s*/i, '').gsub(/\s+/, ' ').strip
    return answer unless answer.empty?

    puts "    ⚠ #{t[:name]} 第#{attempt + 1}次空交卷，重试…" if attempt < 2
  end
  ''
end

if ARGV.include?('--dry')
  puts 'DRY：不调用 LLM。'
  TRANSFER.each { |t| puts "  #{t[:name]} [#{t[:course]}] #{t[:q][0, 60]}…" }
  exit 0
end

abort '需要 AGNES_API_KEY' if ENV['AGNES_API_KEY'].to_s.empty?

rows = TRANSFER.map do |t|
  answer = run_question(t)
  # 三态：PASS 作答且判分对 / FAIL 作答但判分错 / VOID 空交卷（重试后仍空，不算答错）
  verdict = if answer.empty?
              'VOID'
            elsif t[:oracle].call(answer)
              'PASS'
            else
              'FAIL'
            end
  puts "  #{verdict}  #{t[:name]} [#{t[:course]}] -> #{answer[0, 110]}"
  { name: t[:name], course: t[:course], verdict: verdict, answer: answer[0, 120] }
end

passed = rows.count { |r| r[:verdict] == 'PASS' }
failed = rows.count { |r| r[:verdict] == 'FAIL' }
void = rows.count { |r| r[:verdict] == 'VOID' }
puts
puts "════════ 转移测验 ════════"
puts "  PASS #{passed} / FAIL #{failed} / VOID #{void}（共 #{TRANSFER.size}）"
puts "  作答率 #{passed + failed}/#{TRANSFER.size} 中答对 #{passed}"
puts "  作答正确率 = #{passed}/#{passed + failed}"
puts "  VOID = 模型空交卷（会话问题，非答错；已重试 3 次）"

Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
artifact = File.join(ROOT, 'examples', 'gradebook', "transfer_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
File.write(artifact, JSON.pretty_generate(
  generated_at: Time.now.iso8601,
  model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
  total: TRANSFER.size, passed: passed, failed: failed, void: void,
  rows: rows
))
puts "  证据存档: #{artifact}"