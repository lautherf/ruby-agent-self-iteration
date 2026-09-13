$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'

ROOT = File.expand_path('..', __dir__)
RA = File.expand_path('plugins/ra.rb', ROOT)
LESSONS = File.expand_path('examples/lessons.rb', ROOT)

# 能力/经验分舱审计（离线，不烧 LLM）。
# 动机：外人视角反思第六条——"未经验证的'经验'混在验证过的能力里"。
# 本脚本把两船分开点数：
#   · A 舱 · 已验证能力：plugins/ra.rb 里有 @doc role 契约的方法（经 teach→verify 验收）
#   · B 舱 · 经验沉淀：lessons.rb 里的 lesson（按 grade 分 ── verified / sop / note）
# 用法：
#   ruby -Ilib examples/audit_knowledge.rb           # 打印分舱报告
#   ruby -Ilib examples/audit_knowledge.rb --ci      # 有未分级经验/无契约方法则退出码 1
CI = ARGV.include?('--ci')

# —— A 舱：方法契约 ——
ra = RubyAgent::DocPlugin.new('ra', RA).load!
identity = %w[self_intro what_i_learned what_i_must_not]
bare = ra.registry.keys.reject { |m| identity.include?(m) }

# —— B 舱：经验 ——
kb = RubyAgent::Knowledge.new(LESSONS)
lessons = kb.lessons
by_grade = lessons.group_by { |l| l[:grade] }
ungraded_path = lessons.reject { |l| l[:grade] }

puts '════════ A 舱 · 已验证能力（@doc role 契约）════════'
puts "  plugins/ra.rb 方法数: #{ra.registry.size}  #{bare.join(' ')}"
puts
puts '════════ B 舱 · 经验沉淀（grade 分舱）════════'
%w[verified sop note].each do |g|
  list = by_grade.fetch(g, [])
  puts "  [#{g}] x#{list.size}"
  list.each { |l| puts "       #{l[:id]}  #{l[:note].to_s[0, 44]}…" }
end
missing = lessons.reject { |l| l[:grade] == 'verified' || l[:grade] == 'sop' || l[:grade] == 'note' }
puts
puts "  未分级经验: #{missing.size}  #{missing.map { |l| l[:id] }.join(', ')}"
puts
puts '════════ 结论 ════════'
puts "  A 舱 #{bare.size} 个可验证能力（进 verify 流程的真资产）"
puts "  B 舱 #{lessons.size} 条经验（verified 经过复核 / sop 带回归集 / note 是现场笔记，注入前需人审）"
puts '  → 两船已分舱：能力=军械库，经验=行走笔记，不再混为一谈。'

exit(missing.empty? ? 0 : 1) if CI