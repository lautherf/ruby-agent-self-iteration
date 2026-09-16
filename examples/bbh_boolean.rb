# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'json'
require 'time'

# B1：BBH·boolean_expressions 接入实验——分层升降维的"机械可降维"面。
#   与三物排序题相反：本任务输入已是符号规格（True/False/not/and/or + 括号），
#   语义层零职责（无自然语言歧义、无领域概念），真值模型=布尔代数 →
#   机器全链闭环（tokenizer + 递归下降求值器 + 真值枚举）。
#   分层定位：h<-mechanical（SOP-NL-03 mode），LLM 语义层不介入；这本身就是
#   诚实分层的判决：可机解即全机解，不为"看起来该用 LLM"而用 LLM。
#
# 用法：ruby -Ilib examples/bbh_boolean.rb <boolean_expressions.json> [--limit N] [--gold]
#       --gold: 跳过存档读取（本体就是机器判，离线可复现 250/250）
# 判分：机器求值 == 官方 target → PASS；求值异常/溢出 → FAIL（crash）。
ROOT = File.expand_path('..', __dir__)

def tokenize(code)
  code.gsub(/\bis\b\s*$/, '').scan(/not|and|or|True|False|\(|\)|[A-Za-z]+/).map(&:strip)
end

# 递归下降：expr := term (or term)* ; term := factor (and factor)* ; factor := not* atom|(...)
class BoolEval
  def initialize(tokens)
    @tokens = tokens
    @pos = 0
  end

  def run
    raise '空表达式' if @tokens.empty?

    val = parse_expr
    raise "残留 token #{@tokens[@pos..].inspect}" unless @pos >= @tokens.size

    val
  end

  private

  def parse_expr
    val = parse_term
    while @tokens[@pos] == 'or'
      @pos += 1
      rhs = parse_term
      val = val || rhs
    end
    val
  end

  def parse_term
    val = parse_factor
    while @tokens[@pos] == 'and'
      @pos += 1
      rhs = parse_factor
      val = val && rhs
    end
    val
  end

  def parse_factor
    if @tokens[@pos] == 'not'
      @pos += 1
      return !parse_factor
    end
    if @tokens[@pos] == '('
      @pos += 1
      v = parse_expr
      raise '缺右括号' unless @tokens[@pos] == ')'

      @pos += 1
      return v
    end
    t = @tokens[@pos]
    @pos += 1
    case t
    when 'True' then true
    when 'False' then false
    else raise "未知 token #{t.inspect}"
    end
  end
end

def evaluate(tokens)
  BoolEval.new(tokens).run
end

def main
  path = ARGV.find { |a| !a.start_with?('--') }
  limit = (i = ARGV.index('--limit')) ? ARGV[i + 1].to_i : 250
  data = JSON.parse(File.read(path))
  rows = []
  stats = { pass: 0, fail_miss: 0, crash: 0 }
  data['examples'].first(limit).each_with_index do |ex, i|
    input = ex['input']
    target = ex['target'].to_s.strip
    begin
      got = evaluate(tokenize(input))
      got = got ? 'True' : 'False'
      pass = got == target
      stats[pass ? :pass : :fail_miss] += 1
      rows << { idx: i, verdict: pass ? 'PASS' : 'FAIL', input: input, machine: got, target: target }
      puts "  %s   #%03d [%s%s] %s" % [pass ? 'PASS' : 'FAIL', i, got, (pass ? '==' : '!='), target[0, 20]]
    rescue StandardError => e
      stats[:crash] += 1
      rows << { idx: i, verdict: 'FAIL', diag: "crash #{e.message[0, 50]}", input: input }
      puts "  FAIL   #%03d [crash] %s" % [i, e.message[0, 60]]
    end
  end
  puts "═══ 结果 #{stats[:pass]}/#{rows.size} PASS  #{stats.to_json} ═══"
  Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
  art = File.join(ROOT, 'examples', 'gradebook', "bbh_boolean_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(art, JSON.pretty_generate(generated_at: Time.now.iso8601, model: 'machine', total: rows.size, rows: rows))
  puts "  存档: #{art}"
end

main if $PROGRAM_NAME == __FILE__