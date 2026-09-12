# frozen_string_literal: true

# 对话式教学 ▸ 初中 / 高中数学知识沉淀
# 老师（本脚本）只出"知识点 + 语义 + 外部验收题"；怎么实现、写什么用例、怎么下契约，
# 全由 ra（真模型 agent）在对话中自己用工具完成：
#   library 自查 → apply_code 写实现 → verify 自证 → teach 写 @doc → Final Answer
# 老师再用一份"外部验收卷"复验——模型自学 + 第三方复验，双闸门。
#
# 用法：AGNES_API_KEY=sk-xxx ruby -Ilib examples/learn_math_dialogue.rb [初中|高中|all]
# 默认 all。

require 'fileutils'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

STAGES = {
  '初中' => [
    { name: 'abs',        sem: '绝对值 |x|，x 为整数/负数/0/小数' },
    { name: 'gcd',        sem: '最大公约数 gcd(a,b)，a,b 为非负整数；gcd(a,0)=a，gcd(0,0)=0' },
    { name: 'lcm',        sem: '最小公倍数 lcm(a,b)，a,b 为正整数' },
    { name: 'is_prime?',  sem: '素数判断：n 为 >=2 的整数时是否素数，否则 false' }
  ],
  '高中' => [
    { name: 'factorial',      sem: '阶乘 n!，n 为非负整数；0!=1；负数抛 ArgumentError' },
    { name: 'permutation',    sem: '排列数 P(n,k)=n!/(n-k)!，0<=k<=n' },
    { name: 'combination',    sem: '组合数 C(n,k)=n!/(k!(n-k)!)，0<=k<=n' },
    { name: 'arithmetic_sum', sem: '等差数列前 n 项和 S=n(2a1+(n-1)d)/2' }
  ]
}.freeze

# 老师的外部验收卷（不给模型）：模型自己写的 verify 只是自证，这里才是复验
ACCEPT = {
  'abs' => [{ 'args' => [-3], 'expected' => 3 }, { 'args' => [0], 'expected' => 0 }, { 'args' => [2.5], 'expected' => 2.5 }],
  'gcd' => [{ 'args' => [12, 18], 'expected' => 6 }, { 'args' => [5, 0], 'expected' => 5 }, { 'args' => [0, 0], 'expected' => 0 }],
  'lcm' => [{ 'args' => [4, 6], 'expected' => 12 }, { 'args' => [7, 3], 'expected' => 21 }],
  'is_prime?' => [{ 'args' => [2], 'expected' => true }, { 'args' => [1], 'expected' => false },
                  { 'args' => [17], 'expected' => true }, { 'args' => [9], 'expected' => false }],
  'factorial' => [{ 'args' => [0], 'expected' => 1 }, { 'args' => [5], 'expected' => 120 },
                  { 'args' => [-1], 'raises' => 'ArgumentError' }],
  'permutation' => [{ 'args' => [5, 2], 'expected' => 20 }, { 'args' => [4, 0], 'expected' => 1 }],
  'combination' => [{ 'args' => [5, 2], 'expected' => 10 }, { 'args' => [4, 4], 'expected' => 1 }],
  'arithmetic_sum' => [{ 'args' => [1, 1, 10], 'expected' => 55 }, { 'args' => [2, 3, 4], 'expected' => 26 }]
}.freeze

stage_arg = (ARGV[0] || 'all').to_s
stages = stage_arg == 'all' ? STAGES.keys : [stage_arg]
abort "阶段只能是 初中/高中/all" unless stages.all? { |s| STAGES.key?(s) }

base_url = ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1'
model    = ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
key      = ENV['AGNES_API_KEY'] or abort '缺少 AGNES_API_KEY'

ra = RubyAgent::DocPlugin.new('ra', File.expand_path('../plugins/ra.rb', __dir__)).load!
knowledge = RubyAgent::Knowledge.new(File.expand_path('lessons.rb', __dir__))
hub = RubyAgent::DocHub.new
hub.mount(ra)
hub.mount(RubyAgent::DocPlugin.new(RubyAgent::Knowledge::NAME, knowledge.path).load!)

llm = RubyAgent::DeepSeekAdapter.new(base_url: base_url, api_key: key, model: model)
agent = RubyAgent::AgentLoop.new(hub: hub, llm: llm, knowledge: knowledge, max_steps: 40,
                                 writable_plugins: ['ra'])

agent.on(:tool_call) do |e|
  brief = e[:input].to_s.gsub(/\s+/, ' ')[0, 110]
  puts "    → #{e[:tool]} #{brief}"
end
agent.on(:verify) { |e| puts "      判题: #{e[:ok] ? '√' : '✗'} #{e[:plugin]}##{e[:method]}" }

MAX_ATTEMPTS = 3

results = []
stages.each do |stage|
  STAGES[stage].each_with_index do |unit, i|
    puts "\n#{'=' * 62}\n【老师】#{stage}数学 · 第 #{i + 1} 课：#{unit[:name]}（#{unit[:sem]}）\n#{'=' * 62}"

    task = <<~TASK
      你是 ra。老师在教你#{stage}数学，本课要内化的能力是：
        方法名：#{unit[:name]}
        语义：#{unit[:sem]}

      请严格按以下流程，逐步调用工具完成，不许跳步、不许心算替代代码：
        1. 调用 library（plugin=ra）自查方法库，确认不与方法库里已有方法撞名；
        2. 调用 apply_code（plugin=ra, method=#{unit[:name]}, code=...）写入 Ruby 实现；
        3. 调用 verify（plugin=ra, method=#{unit[:name]}, cases=[...]）自验：
           至少 2 个用例，必须覆盖边界（如 0 / 负数 / 异常）；
        4. 若 verify 未通过，用 apply_code 修正实现，再次 verify，直到通过；
        5. 调用 teach（plugin=ra, method=#{unit[:name]}, role=一句话契约）写下 @doc；
        6. 最后用 Final Answer 报告：方法名、verify 通过情况、用例数。
    TASK

    attempt = 0
    acc = nil
    loop do
      attempt += 1
      agent.run(task)
      acc = agent.invoke_tool('verify', { 'plugin' => 'ra', 'method' => unit[:name], 'cases' => ACCEPT[unit[:name]] })
      break if acc.start_with?('验证通过') || attempt >= MAX_ATTEMPTS

      puts "  【老师】复验未过，反馈第 #{attempt} 次，请修正后重做："
      task = <<~TASK
        ra，老师复验你刚才的「#{unit[:name]}」没有通过。失败原因：
          #{acc}

        请排查并修正：
          1. 你是否真的用 apply_code 写入了 def #{unit[:name]}？若跳过了，现在补上；
          2. 用 read_code（plugin=ra, method=#{unit[:name]}）看看当前实现哪里不对；
          3. apply_code 修正 → verify 自验（含边界）→ teach 写 @doc → Final Answer。
        目标语义：#{unit[:sem]}。注意绝对值、负数、0 等边界。
      TASK
    end

    ok = acc.start_with?('验证通过')
    results << [stage, unit[:name], ok, attempt, acc]
    puts "  【老师复验】#{ok ? '√ 通过' : '✗ 未过'}（第 #{attempt} 次尝试）— #{acc}"
  end

  puts "\n#{'=' * 62}\n【老师】#{stage}数学 · 阶段复盘：请自己 learn 沉淀经验\n#{'=' * 62}"
  before = knowledge.lessons.size
  review_task = <<~TASK
    你刚学完#{stage}数学。请调用 learn 工具沉淀一条精炼经验：
      - 方法名清单 + 每个方法的语义要点与关键边界（0 / 负数 / 异常）；
      - 学习过程踩过的 1-2 个坑。
    ⚠️ 硬性要求：经验正文控制在 450 字符以内（知识库有长度闸门，超过会被拒绝），写要点、别写长文。
    tags 用 "#{stage}数学,知识沉淀"。调用 learn 后，用 Final Answer 报告经验编号。
  TASK
  review_ok = false
  MAX_ATTEMPTS.times do |attempt|
    agent.run(review_task)
    knowledge.load!
    if knowledge.lessons.size > before
      review_ok = true
      puts "  【老师】learn 沉淀成功：经验 #{knowledge.lessons.last[:id]}"
      break
    end

    puts "  【老师】learn 未入库（多半超 500 字被闸门拒绝）— 第 #{attempt + 1} 次反馈压稿"
    review_task = <<~TASK
      ra，你的经验没被知识库接受（超过 450 字长度闸门被拒）。请重新调用 learn：
        - 一句话方法清单（方法名逗号分隔）；
        - 每个方法只写最关键边界；
        - 全程正文 ≤400 字，禁止 markdown 长文。
      tags 用 "#{stage}数学,知识沉淀"。调用 learn 后 Final Answer 报告编号。
    TASK
  end
  results << [stage, 'learn复盘', review_ok, 0, review_ok ? 'ok' : "仍失败(经验 #{before}→#{knowledge.lessons.size})"]
end

puts "\n#{'=' * 62}\n【复盘】ra 数学方法库\n#{'=' * 62}"
puts agent.invoke_tool('library', { 'plugin' => 'ra' })
knowledge.load!
puts "\n【经验库】"
knowledge.lessons.each { |l| puts "  #{l[:id]}: #{l[:note][0, 50]}…" }

pass = results.count { |_, _, ok, _, _| ok }
puts "\n【成绩】#{pass}/#{results.size}（每课最多 #{MAX_ATTEMPTS} 次对话纠错机会）"
results.reject { |_, _, ok, _, _| ok }.each { |s, n, _, at, a| puts "  ✗ #{s}·#{n}（试了 #{at} 次）: #{a}" }
exit(pass == results.size ? 0 : 1)