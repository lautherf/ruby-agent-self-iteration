# frozen_string_literal: true

# RA 自修复闭环：植入 bug 的 bbh 插件 + verify 失败观察 → Agent 自主定位并修复。
#
# 演示框架能力（Sprint 6 自修改 + 自动回滚 + 经验沉淀）：
#   1. plugins/bbh.rb 被（外部）植入 target_pos bug（:t_abs/:t 漏了 n-rank+1 反转）。
#   2. 修复 Agent 拿到 verify 失败观察：target_pos(2,:t_abs,5) 应=4 实=2。
#   3. Agent read_code 定位 → apply_code 修复 → verify 全部用例通过 → learn 沉淀教训。
#
# 用法：AGNES_API_KEY=sk-... ruby -Ilib examples/bbh_self_fix_demo.rb [--offline-mock]

require 'json'
$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'tmpdir'

ROOT = File.expand_path('..', __dir__)
BBH_PLUGIN = File.join(ROOT, 'plugins', 'bbh.rb')
LESSONS = File.join(ROOT, 'examples', 'lessons.rb')

def llm_adapter
  RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'],
    model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
end

def snapshot
  File.read(BBH_PLUGIN)
end

def restore!(snap)
  File.write(BBH_PLUGIN, snap)
end

# 验证 target_pos 是否被修复（与正确语义比对）
def verify_plugin!
  mod = Module.new
  mod.module_eval(File.read(BBH_PLUGIN), BBH_PLUGIN, 1)
  obj = Object.new.extend(mod)
  checks = {
    [2, :t_abs, 5] => 4, [3, :t, 7] => 5, [1, :abs, 5] => 1, [3, :h, 7] => 3
  }
  checks.map do |(r, s, n), want|
    got = mod.respond_to?(:target_pos) ? mod.send(:target_pos, r, s, n) : obj.target_pos(r, s, n)
    [got == want, "#{s}(#{r},#{n})=#{got} want #{want}"]
  end
end

# 任务：让 Agent 修复 target_pos（给 verify 失败观察做锚）
TASK = <<~TASK
  bbh 插件的 target_pos 方法有 bug：从右数（:t_abs 尾端 :t 与物理 :t_abs）定位时
  忘了把 rank 反转到左起下标，导致方向反的题全错。
  请你修复它，必须：
  1) read_code 读 target_pos 当前实现；
  2) 判断正确语义，apply_code 修复（:abs 与 :h 原样返回 rank；:t_abs 与 :t 返回 n-rank+1）；
  3) verify 锁定目标：cases=[{args:[2,:t_abs,5],expected:4},
     {args:[3,:t,7],expected:5},{args:[1,:abs,5],expected:1},{args:[3,:h,7],expected:3}]，
     任一不过会自动回滚；
  4) learn 沉淀这次教训（tags: bbh.target_pos）；
  5) Final Answer 总结修复方法与 verify 结果。
TASK

# 离线 mock：用固定序列模拟 Agent（确定性地"修复"），验证编排闭环；真机则真调 LLM。
def mock_llm
  steps = [
    %(Action: read_code\nAction Input: {"plugin":"bbh","method":"target_pos"}),
    %(Action: apply_code\nAction Input: {"plugin":"bbh","method":"target_pos","code":"def target_pos(rank, side, n)\n  case side\n  when :abs, :h then rank\n  else n - rank + 1\n  end\nend"}),
    %(Action: verify\nAction Input: {"plugin":"bbh","method":"target_pos","cases":[{"args":[2,:t_abs,5],"expected":4},{"args":[3,:t,7],"expected":5},{"args":[1,:abs,5],"expected":1},{"args":[3,:h,7],"expected":3}]}),
    %(Action: learn\nAction Input: {"lesson":"target_pos :t_abs/:t 须 n-rank+1 反转以防方向全程反","tags":"bbh.target_pos"}),
    'Final Answer: 修复了 target_pos：:t_abs 与 :t 返回 n-rank+1，:abs/:h 原样 rank；verify 4 例全过。'
  ]
  RubyAgent::MockLLM.new(steps.map { |s| "#{s}\n#{s.start_with?('Final') ? '' : 'Thought: 继续'}" })
end

def main
  snap = snapshot
  offline = ARGV.include?('--offline-mock')
  puts "═══ RA 自修复闭环（#{offline ? '离线 mock' : '真机 agnes'}）═══"
  # 1) 确认 bug 在
  before = verify_plugin!
  puts "植入 bug 检测: #{before.map { |ok, t| t }.join('; ')}"
  abort 'bug 已不存在，先植入 target_pos bug（:t_abs/:t 去掉 n-rank+1）再跑' if before.all?(&:first)

  # 2) 构造修复 Agent
  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('bbh', BBH_PLUGIN).load!)
  kb = RubyAgent::Knowledge.new(LESSONS)
  agent = RubyAgent::AgentLoop.new(
    hub: hub, llm: offline ? mock_llm : llm_adapter, max_steps: 10,
    writable_plugins: ['bbh'], knowledge: kb
  )
  agent.on(:tool_call) { |e| puts "  → #{e[:tool]} #{e[:input].to_s[0, 90]}" }
  agent.on(:verify)     { |e| puts "  ★ verify ok=#{e[:ok]} #{e[:method]} #{e[:cases]}例" }
  agent.on(:rollback)   { |e| puts "  ★ rollback: #{e[:method]}" }
  agent.on(:code_change){ |e| puts "  ★ #{e[:plugin]}##{e[:method]} → #{e[:status]}" }

  answer = agent.run(TASK)
  puts "  Final: #{answer.inspect[0, 120]}"

  # 3) 事后验证
  after = verify_plugin!
  ok = after.all?(&:first)
  puts "修复后检测: #{after.map { |ok2, t| t }.join('; ')}"
  puts "\n═══ result: #{ok ? 'RA 自修复成功' : 'RA 未修复'}（磁盘插件 #{ok ? '已修复' : '保持 bug（自动回滚保护）'}）═══"
  restore!(snap) unless ok   # 未修复则恢复初始插件，防污染
  # 沉淀的 lesson 看知识库
  kb.load!
  kb.lessons.select { |l| l[:tags].to_s.include?('bbh') || l[:note].to_s.include?('target_pos') }.each { |l| puts "  lesson #{l[:id]}: #{l[:note]}" }
end

main if $PROGRAM_NAME == __FILE__