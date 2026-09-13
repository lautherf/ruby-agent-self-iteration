$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'json'
require 'time'

# 消融对照（Ablation）—— 把"成绩单"分成底子与平台。
#
# 动机（外人反思 #2）：成绩单必须分账——LLM 底子 X 分、方法库/经验库净增量 Y 分。
# 方法：同一基准题库，跑 4 组配置（逐级叠加）：
#   cfg0 裸 LLM（不挂任何插件）      ← 底子
#   cfg1 +ra 方法库                 ← 方法层净增量
#   cfg2 +ra+lessons                ← 经验层净增量
#   cfg3 +ra+lessons+SOP 全量        ← 方法论的净增量
# 每道题都有机械判分 oracle（数值/正则），不许肉眼给分。
# 成绩与判答题面存进 examples/gradebook/ablation_<ts>.json 存档，报告即证据链。
#
# 用法：
#   ruby -Ilib examples/ablation.rb            # 真实跑 4 组 × 题库（烧 LLM）
#   ruby -Ilib examples/ablation.rb --dry      # 只打印题面与配置，不烧 LLM
ROOT = File.expand_path('..', __dir__)
GRADEBOOK_DIR = File.join(ROOT, 'examples', 'gradebook')

# 基准题库：{ name:, q:, oracle: proc -> true/false }，乙类题要求模型只给答案。
# 第一版全标准题（gcd/xor/阶乘）裸 LLM 也 3/3，净增量 0 —— 证明"标准题不是方法库的用武之地"。
# 方法库的真正价值在：边界/异常语义、大数组合计算、数值精确性 —— 这些才是裸 LLM 飘、方法库稳的地方。
BENCHMARK = [
  {
    name: 'gcd-12-18',
    q: '只输出一个数字：12 和 18 的最大公约数等于几？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(6)(?:[^\d]|$)/) }
  },
  {
    name: 'combination-40-20',
    q: '只输出一个数字：组合数 C(40,20) 等于多少？',
    oracle: ->(a) { a.include?('137846528820') }
  },
  {
    name: 'lcm-35-49',
    q: '只输出一个数字：lcm(35, 49) 等于多少？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(245)(?:[^\d]|$)/) }
  },
  {
    name: 'vec-norm-130',
    q: '只输出一个数字：向量 [3,4,0,12] 的 L2 范数（欧几里得长度）是多少？',
    oracle: ->(a) { a.match?(/(?:^|[^\d])(13)(?:[^\d]|$)/) }
  },
  {
    name: 'div-zero',
    q: '只输出异常类名：整数除法 1/0 会抛出什么异常？（不要给别的文字）',
    oracle: ->(a) { a.match?(/ArgumentError/i) }
  },
  {
    name: 'prime-97',
    q: '只输出 true 或 false：97 是素数吗？',
    oracle: ->(a) { a.match?(/true/i) && !a.match?(/false/i) }
  }
].freeze

def build_llm
  RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
end

# cfg0=原始 LLM 直答（无 AgentLoop、无插件、无经验）＝最纯粹的"底子"；
# 其余走 AgentLoop 逐级叠加。
def ask(level, q)
  llm = build_llm
  return llm.chat([{ role: 'user', content: q }]).to_s if level.zero?

  hub = RubyAgent::DocHub.new
  knowledge = RubyAgent::Knowledge.new(File.join(ROOT, 'examples', 'lessons.rb'))
  ra_path = File.join(ROOT, 'plugins', 'ra.rb')
  hub.mount(RubyAgent::DocPlugin.new('ra', ra_path).load!) if level >= 1
  hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!) if level >= 2
  agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge,
                                   max_steps: 8, writable_plugins: ['ra'])
  agent.run(q).to_s
end

CONFIGS = [
  { key: 'cfg0_裸LLM', level: 0 },
  { key: 'cfg1_+ra方法库', level: 1 },
  { key: 'cfg2_+lessons', level: 2 },
  { key: 'cfg3_全量', level: 3 }
].freeze

if ARGV.include?('--dry')
  puts 'DRY：不调用 LLM。'
  CONFIGS.each { |c| puts "  #{c[:key]}" }
  BENCHMARK.each { |b| puts "  题: #{b[:name]}  #{b[:q]}" }
  exit 0
end

abort '需要 AGNES_API_KEY（export AGNES_API_KEY=…）' if ENV['AGNES_API_KEY'].to_s.empty?

results = []
CONFIGS.each do |cfg|
  row = { config: cfg[:key], score: 0 }
  BENCHMARK.each do |bench|
    out = begin
      ask(cfg[:level], bench[:q])
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 60]}"
    end
    answer = out.sub(/Final Answer:?\s*/i, '').gsub(/\s+/, ' ').strip
    ok = bench[:oracle].call(answer)
    row[:score] += 1 if ok
    row[bench[:name]] = { ok: ok, answer: answer[0, 120] }
    puts "  [#{cfg[:key]}] #{bench[:name]}: #{ok ? 'PASS' : 'FAIL'}  -> #{answer[0, 100]}"
  end
  results << row
  puts "  小计 [#{cfg[:key]}] #{row[:score]}/#{BENCHMARK.size}"
  puts
end

baseline = results.find { |r| r[:config] == 'cfg0_裸LLM' }[:score]
full = results.find { |r| r[:config] == 'cfg3_全量' }[:score]
puts "════════ 成绩单分账 ════════"
puts "  LLM 底子（裸跑）:  #{baseline}/#{BENCHMARK.size}"
puts "  平台净增量(全量-底子): #{'+' if full > baseline}#{full - baseline}/#{BENCHMARK.size}"

Dir.mkdir(GRADEBOOK_DIR) unless File.directory?(GRADEBOOK_DIR)
ts = Time.now.strftime('%Y%m%d-%H%M')
artifact = File.join(GRADEBOOK_DIR, "ablation_#{ts}.json")
File.write(artifact, JSON.pretty_generate(
  generated_at: Time.now.iso8601,
  model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash',
  benchmark_size: BENCHMARK.size,
  results: results
))
puts "  证据存档: #{artifact}"