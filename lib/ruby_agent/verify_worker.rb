# frozen_string_literal: true

# verify 的隔离执行体 —— 权限分层（三件套之二）的执行侧落地。
#
# 背景：原来的 verify 在 AgentLoop 主进程内 eval 任意 assert 表达式。
#       一个含 system("...") / File.delete 的 assert 就能逃逸并带走整个进程。
#       隔离后，Agent 给的验证代码在**独立子进程**里运行：
#       恶意或写坏的 Ruby 只会炸掉 worker，AgentLoop 主进程与宿主文件不受影响。
#
# 协议（与父进程的接口是一份 JSON）：
#   stdin  → {"file": 插件文件路径, "method": 方法名, "forms": [{args, expected|raises|assert}, ...]}
#   stdout → {"results": [{ok, actual, expected, text}, ...]}
#   子进程异常退出（如 assert 里 exit!）时 stdout 为空，父进程须兜底为失败项。
#
# 单独运行调试：echo '...json...' | ruby lib/ruby_agent/verify_worker.rb

require 'json'

module RubyAgentWorker
  module_function

  def run(payload)
    file   = payload['file'].to_s
    method = payload['method'].to_s
    forms  = payload['forms'] || []

    mod = Module.new
    mod.module_eval(File.read(file), file, 1)
    obj = Object.new.extend(mod)

    forms.map { |form| run_one(mod, obj, method, Array(form['args']), form, file) }
  end

  # 单条验证项：真实求值 + 三种形态（值相等 / 抛错 / 布尔断言）。
  # 文本措辞与回报格式是父进程拼 observation 的依据，改动需配套测试。
  def run_one(mod, obj, method, args, form, file)
    arg_text = args.map(&:inspect).join(', ')
    call = proc { mod.respond_to?(method) ? mod.send(method, *args) : obj.send(method, *args) }

    if form.key?('raises')
      begin
        actual = call.call
        { ok: false, actual: actual.inspect,
          text: "#{method}(#{arg_text}) 期望抛 #{form['raises']} 但正常返回 #{actual.inspect}" }
      rescue NoMethodError, StandardError => e
        wanted = Object.const_get(form['raises'].to_s) rescue nil
        if wanted && e.is_a?(wanted)
          { ok: true, actual: nil, text: "#{method}(#{arg_text}) 抛 #{e.class} 符合预期" }
        else
          { ok: false, actual: e.class.to_s,
            text: "#{method}(#{arg_text}) 期望抛 #{form['raises']} 实际抛 #{e.class}: #{e.message}" }
        end
      end
    else
      begin
        actual = call.call
        if form.key?('assert')
          verdict = obj.instance_eval("result = #{actual.inspect}\n(#{form['assert']})", file, 1)
          if verdict
            { ok: true, actual: actual.inspect,
              text: "#{method}(#{arg_text}) 断言 #{form['assert']} 成立 (#{actual.inspect})" }
          else
            { ok: false, actual: actual.inspect,
              text: "#{method}(#{arg_text}) 断言 #{form['assert']} 不成立 (实际 #{actual.inspect})" }
          end
        else
          expected = form['expected'].to_s
          if actual.to_s == expected
            { ok: true, actual: actual, text: "#{method}(#{arg_text}) = #{actual}" }
          else
            { ok: false, actual: actual, expected: expected,
              text: "#{method}(#{arg_text}) 期望=#{expected} 实际=#{actual}" }
          end
        end
      rescue NoMethodError, StandardError => e
        { ok: false, actual: "#{e.class}: #{e.message}",
          text: "调用 #{method}(#{arg_text}) 抛 #{e.class}: #{e.message}" }
      end
    end
  end
end

if __FILE__ == $0
  payload = JSON.parse($stdin.read)
  puts JSON.generate(results: RubyAgentWorker.run(payload))
end