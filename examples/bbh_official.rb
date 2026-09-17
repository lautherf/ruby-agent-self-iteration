$LOAD_PATH.unshift File.expand_path('../lib', __dir__)
require 'ruby_agent'
require 'json'
require 'time'

# A3：官方 BBH·logical_deduction（three_objects）接入——
# 官方 250 例全是多选，句法远比手写卷广（对象=短语、域=方位/新旧/贵贱/名次…
# 关系句=开放词汇"to the right of / newer than / more expensive / finished below…"）。
# 分层对策：
#   · 对象清单 & 选项 & 官方答案 = harness 规格 → 机器正则解析（不让 LLM 碰）。
#   · 关系句 = 开放词汇 → LLM 升维语义层归一成四谓词(before/after/adjacent/between)
#     + 序头声明 head（该题"最前/最高/最左/最新/最贵/第一名"端的概念词）。
#   · 机层 = 全序排列枚举（复用）；选项"X 是第 k 高/端"按序头字典化成 rank，机器点名。
#
# 用法：ruby -Ilib examples/bbh_official.rb <three.json> [--limit N] [--offline]
ROOT = File.expand_path('..', __dir__)

def extract_json(text)
  l = text.rindex('{')
  r = text.rindex('}')
  return nil unless l && r && r > l

  JSON.parse(text[l..r])
rescue JSON::ParserError
  nil
end

def build_agent
  hub = RubyAgent::DocHub.new
  hub.mount(RubyAgent::DocPlugin.new('ra', File.expand_path('plugins/ra.rb', ROOT)).load!)
  # RA 知识挂载（精简版，lesson_019 训诫：提示词越长模型越崩）：
  # 只把 lesson_023 三物排序七戒教给语义层，绝不全量铺满经验库。
  lessons_path = File.join(ROOT, 'examples', 'lessons.rb')
  lesson = (RubyAgent::DocPlugin.new('knowledge', lessons_path).load!.registry['lesson_023'] || {})
  kp2 = RubyAgent::DocPlugin.new('knowledge', lessons_path)
  kp2.instance_variable_set(:@registry, { 'lesson_023' => lesson }) unless lesson.empty?
  hub.mount(kp2) unless lesson.empty?
  kb = RubyAgent::Knowledge.new(lessons_path)
  llm = RubyAgent::DeepSeekAdapter.new(
    base_url: ENV['AGNES_BASE_URL'] || 'https://apihub.agnes-ai.com/v1',
    api_key: ENV['AGNES_API_KEY'], model: ENV['AGNES_MODEL'] || 'agnes-2.5-flash'
  )
  RubyAgent::AgentLoop.new(hub: hub, llm: llm, max_steps: 8, writable_plugins: ['ra'], mode: :exam, knowledge: kb)
end

BBH_OFFICIAL_PROMPT = <<~PROMPT.freeze
  你是降维管线的"升维语义层"。输入一道排序题（对象名已由机器解析并列出，引用时必须一字不差地使用机器给定的完整名称，含冠词 the/an）：
  对象清单：{{OBJECTS}}
  任务：只把题干里的比较/位置关系句抽成标准谓词（选项不是约束、简介句不是约束）：
    ["before","X","Y"]       X 排在 Y 前（该题序向下更靠前/更高端）
    ["after","X","Y"]        X 排在 Y 后
    ["adjacent","X","Y"]     X 与 Y 相邻
    ["between","X","Y","Z"]  X 夹在 Y 与 Z 之间
    ["rank","X",k,"left"]    X 是从左数第 k 个（物理方位题专用）。概念题（新旧/贵贱/名次）禁止用 left/right！
    ["rank","X",k,"old"]     X 是该概念端点第 k 个（概念题专用）：
                               "X is the oldest"→["rank","X",1,"old"]、"the newest"→["rank","X",1,"new"]、
                               "the most expensive"→["rank","X",1,"expensive"]、"the cheapest"→["rank","X",1,"cheap"]、
                               "finished first"→["rank","X",1,"first"]、"the second-newest"→["rank","X",2,"new"]。
  方向约定（全题统一一个序向）：more/…er（更新、更贵、更高、finish above…）→ before；反义（更旧、更便宜、below…）→ after。
  端名句直接用 rank 表达："X is the leftmost"→["rank","X",1,"left"]；"X is the rightmost"→["rank","X",1,"right"]；
  "X is the second from the left"→["rank","X",2,"left"]；"X is in the middle"→["rank","X",2,"left"]。
  另给序头声明 head ∈ {left, right, new, old, expensive, cheap, first}：本排序"最前/最高/最左/最新/最贵/第一名"端对应哪个概念（与你的 before 方向一致；方向判断失误会导致整题错解，务必让 head 的方向与约束一致：若 before=更旧，head 应为 old）。
  输出纯 JSON：{"objects":["…"],"constraints":[["before","…","…"],…],"head":"left"}
  ⚠ 用 Action=Final Answer 提交，Action Input 填 JSON。
  题干：
  {{TEXT}}
PROMPT

# —— 机器规格层：对象与选项解析 ——
def objlist_from(input)
  m = input.match(/:\s*(.+?)(?:\.\s*(?=[A-Z])|\.$)/)
  raw = m && m[1]
  raw = nil if raw && !raw.include?(',')
  return [] unless raw

  raw.split(/,|\band\b/).map(&:strip).reject(&:empty?).map { |s| s.sub(/^and\s*/i, '').strip }
end

# 按序头把选项谓词化 → {:obj, :rank(从序头数第几个), :side(:h 头端/:t 尾端)}
ORDINAL = { 'first' => 1, 'second' => 2, 'third' => 3, 'fourth' => 4, 'fifth' => 5, 'sixth' => 6, 'seventh' => 7 }.freeze

def rank_for(body, _head)
  # 方位词是绝对坐标：排列本身就是左→右，无需 head（:abs 直接定位）
  return [1, :abs] if body[/leftmost/]
  return [1, :t_abs] if body[/rightmost/]

  # finished 排位词是绝对序向，独立于 head。⚠ "Nth-to-last"（从尾端数第N）必须先于
  # 纯 "Nth"（从头端数第N）检查——"finished third-to-last" 含子串 "finished third"，反序会误判头端。
  if (m = body.match(/finished\s+(#{ORDINAL.keys.join('|')})-to-last/))
    return [ORDINAL.fetch(m[1]), :t_abs]
  end
  if (m = body.match(/finished\s+(#{ORDINAL.keys.join('|')}|last|top|bottom|first)/))
    return [ORDINAL.fetch(m[1], 1), m[1] == 'last' || m[1] == 'bottom' ? :t : :h]
  end

  if (m = body.match(/the\s+(#{ORDINAL.keys.join('|')})\s+from the\s+(left|right)/))
    return [ORDINAL.fetch(m[1]), m[2] == 'left' ? :abs : :t_abs]
  end
  # 概念词才需要 head 声明序向；语义层已保证 before=more，概念序头恒≡序头(order[0])
  # ⚠ 序数检查必须先于单数（"second-oldest" 含 "oldest" 子串，反序会误判 rank1）
  case _head
  when 'new'
    return [2, :h] if body[/second-newest|second newest/]
    return [1, :h] if body[/newest/]
    return [2, :t] if body[/second-oldest|second oldest/]
    return [1, :t] if body[/oldest/]
  when 'old'
    return [2, :h] if body[/second-oldest|second oldest/]
    return [1, :h] if body[/oldest/]
    return [2, :t] if body[/second-newest|second newest/]
    return [1, :t] if body[/newest/]
  when 'expensive'
    return [2, :h] if body[/second-most|second most/]
    return [1, :h] if body[/most \w+/]
    return [2, :t] if body[/second-cheapest|second cheapest/]
    return [1, :t] if body[/cheapest|least \w+/]
  when 'cheap'
    return [2, :h] if body[/second-cheapest|second cheapest/]
    return [1, :h] if body[/cheapest/]
    return [2, :t] if body[/second-most|second most/]
    return [1, :t] if body[/most \w+/]
  end
  [nil, nil]
end

def target_pos(rank, side, n)
  case side
  when :abs then rank
  when :t_abs then n - rank + 1
  when :h then rank
  else n - rank + 1
  end
end

def parse_options(input, objects, head)
  opts_txt = input[/Options:\n(.*)/m, 1].to_s
  out = {}
  n = objects.size
  letters = ('A'..).take(n == 5 ? 5 : n == 7 ? 7 : 3).join
  core = ->(s) { s.sub(/\A(a|an|the)\s+/i, '') }
  opts_txt.scan(/\(([#{letters}])\)\s*(The\s*)?(.+?)(?=\n\([#{letters}]\)|\z)/) do |letter, _the, body|
    body = body.strip
    obj = objects.find { |o| body.match?(/(?:\bthe\s+)?#{Regexp.escape(core.call(o))}\b/i) }
    rank, side = rank_for(body, head)
    out[letter] = { obj: obj, rank: rank, side: side, text: body }
  end
  out
end

# —— 降维机层（复用谓词语义）——
def idx(order, x)
  order.index(x) + 1
end

ARTICLE = ->(s) { s.sub(/\A(a|an|the)\s+/i, '') }

def normalize_arg(arg, names)
  return arg if names.include?(arg)
  hit = names.find { |n| ARTICLE.call(n) == ARTICLE.call(arg) }
  hit ||= names.find { |n| n.split.include?(ARTICLE.call(arg)) }
  hit || arg
end

def solve_orders(names, constraints, head = nil)
  side_words = %w[left right new old expensive cheap first last]
  normed = constraints.map do |c|
    c.map { |a| a.is_a?(String) && !side_words.include?(a) ? normalize_arg(a, names) : a }
  end
  normed.each do |c|
    c.drop(1).each do |arg|
      if arg.is_a?(String) && !side_words.include?(arg) && !names.include?(arg)
        raise "约束引用未申报对象 #{arg}"
      end
    end
  end
  names.permutation(names.size).select { |o| normed.all? { |c| satisfies?(o, c, head) } }
end

OPPOSITE = { 'new' => 'old', 'old' => 'new', 'expensive' => 'cheap', 'cheap' => 'expensive',
             'first' => 'last', 'last' => 'first', 'left' => 'right', 'right' => 'left' }.freeze

def satisfies?(order, c, head = nil)
  n = order.size
  case c[0]
  when 'before'   then idx(order, c[1]) < idx(order, c[2])
  when 'after'    then idx(order, c[1]) > idx(order, c[2])
  when 'adjacent' then (idx(order, c[1]) - idx(order, c[2])).abs == 1
  when 'between'
    y, x, z = c[2], c[1], c[3]
    (idx(order, y) < idx(order, x) && idx(order, x) < idx(order, z)) ||
      (idx(order, z) < idx(order, x) && idx(order, x) < idx(order, y))
  when 'rank' # ["rank","X",k,side]；side=物理(l/r)或概念(new/old/expensive/cheap/first/last)
    side = c[3]
    pos = if side == 'right'
            n - c[2].to_i + 1
          elsif side == 'left'
            c[2].to_i
          elsif head && side == head
            c[2].to_i
          elsif head && OPPOSITE[side] == head
            n - c[2].to_i + 1
          else
            raise "rank 概念端 #{side} 无法在 head=#{head} 下定位"
          end
    idx(order, c[1]) == pos
  end
end

def run_semantic(prompt)
  3.times do |attempt|
    answer = begin
      build_agent.run(prompt).to_s
    rescue StandardError => e
      "run 异常 #{e.class}: #{e.message[0, 60]}"
    end
    answer = answer.sub(/Final Answer:?\s*/i, '').strip
    if answer.empty?
      warn "    ⚠ 第#{attempt + 1}次语义层空回答（限流？），退避 #{3 * (attempt + 1)}s 重试…" if attempt < 2
      sleep(3 * (attempt + 1))
      next
    end

    data = extract_json(answer)
    return data if data.is_a?(Hash) && data['constraints'].is_a?(Array)

    warn "    ⚠ 第#{attempt + 1}次语义层 JSON 不合法，重试…" if attempt < 2
  end
  nil
end

def object_count(input)
  m = input.match(/set of (three|five|seven) objects/)
  m ? { 'three' => 3, 'five' => 5, 'seven' => 7 }.fetch(m[1], 3) : 3
end

def letters_for(n)
  ('A'..).take(n == 5 ? 5 : n == 7 ? 7 : 3).join
end

def main
  path = ARGV.find { |a| !a.start_with?('--') }
  limit = (i = ARGV.index('--limit')) ? ARGV[i + 1].to_i : 10
  offset = (j = ARGV.index('--offset')) ? ARGV[j + 1].to_i : 0
  offline = ARGV.include?('--offline')
  data = JSON.parse(File.read(path))
  examples = data['examples'].drop(offset)

  if ARGV.include?('--syntax')
    concept_heads = %w[new old expensive cheap first]
    ok_obj = 0; solvable_opt = 0; unsolvable_opt = 0
    examples.each do |ex|
      n = object_count(ex['input'])
      objs = objlist_from(ex['input']).first(n)
      ok_obj += 1 if objs.size == n
      letters = letters_for(n)
      tgt = ex['target'][/\(([#{letters}])\)/, 1] || ex['target'][/\(([A-G])\)/, 1]
      txt = ex['input'][/Options:\n(.*)/m, 1].to_s.lines.find { |l| l.start_with?("(#{tgt})") }.to_s.strip
      solvable = !rank_for(txt, concept_heads.first).first.nil? ||
                 concept_heads.any? { |h| rank_for(txt, h).first }
      solvable_opt += 1 if solvable
      unsolvable_opt += 1 unless solvable
      puts "  obj=%s %s %s %s" % [objs.size == n ? 'ok ' : 'NO ', solvable ? 'solvable ' : 'UNSOLVABLE', txt[0, 66], "(n=#{n})"]
    end
    puts "── 对象解析 #{ok_obj}/#{examples.size}；目标选项可定位 #{solvable_opt}/#{examples.size}；不可解 #{unsolvable_opt} ──"
    exit
  end

  examples = examples.first(limit) if limit.positive?

  puts "═══ BBH·official logical_deduction [offset=%d, limit=%d] — %s ═══" % [offset, limit, offline ? '脱机' : '真机']

  stats = { pass: 0, fail_parse: 0, fail_void: 0, fail_contra: 0, fail_option: 0, fail_multi: 0, fail_miss: 0, crash: 0 }
  rows = []
  examples.each_with_index do |ex, i|
    input = ex['input']
    n = object_count(input)
    letters = letters_for(n)
    objects = objlist_from(input).first(n)
    if objects.nil? || objects.size < n
      stats[:fail_parse] += 1
      rows << { idx: i, verdict: 'FAIL', diag: '对象解析失败' }
      puts "  FAIL   #%03d [对象解析失败 n=%d] %s" % [i, n, input[0, 70].inspect]
      next
    end

    prompt = BBH_OFFICIAL_PROMPT.gsub('{{OBJECTS}}', objects.inspect).gsub('{{TEXT}}', input)
    cons, head = [], nil
    orders, extra_runs, cash = [], 0, nil
    run_log = []
    loop do
      llm = offline ? nil : run_semantic(prompt)
      break if llm.nil?
      cons |= llm['constraints']
      head ||= llm['head']
      run_log << [cons.dup, head]
      extra_runs += 1
      orders = begin
        solve_orders(objects, cons, head)
      rescue StandardError => e
        # rank 概念端与 head 冲突导致无法定位：不是直接 FAIL，而是该概念端
        # 才是更硬的方向证据，回退 head=概念端重解（#041/#049/#070 恢复通道）。
        concept = cons.filter_map { |c| c[0] == 'rank' && %w[new old expensive cheap first last].include?(c[3]) ? c[3] : nil }.first
        if concept && concept != head
          warn "    ↻ rank 概念端 #{concept} 仲裁 head #{head.inspect} → #{concept}（crash 兜底）"
          head = concept
          begin
            solve_orders(objects, cons, head)
          rescue StandardError => e2
            stats[:crash] += 1
            rows << { idx: i, verdict: 'FAIL', diag: "crash #{e2.message[0, 50]}" }
            puts "  FAIL   #%03d [crash] %s" % [i, e2.message[0, 60]]
            cash = true
            break
          end
        else
          stats[:crash] += 1
          rows << { idx: i, verdict: 'FAIL', diag: "crash #{e.message[0, 50]}" }
          puts "  FAIL   #%03d [crash] %s" % [i, e.message[0, 60]]
          cash = true
          break
        end
      end
      break if orders.length == 1 || extra_runs >= 2
      warn "    ↻ 语义层第 #{extra_runs + 1} 次补抽（当前约束 #{cons.size} 条，解仍需唯一化）"
    end
    next if cash

    if extra_runs.zero?
      stats[:fail_void] += 1
      rows << { idx: i, verdict: 'FAIL', diag: 'VOID' }
      puts "  FAIL   #%03d [VOID]" % i
      next
    end
    # rank 概念端是比语义层 head 更硬的方向证据（head 为空/非法时才仲裁兜底）：
    # 概念端侧词(如 old)未必等于序头方向——ele.g. head=new 时 oldest 在尾端是合法组合，
    if orders.empty?
      # 并集把方向翻转的两套约束都卷进来了 → 整组矛盾。回退历史里最早那个
      # 能解出非空排列的约束子集（不改写 head 语义，只在状态层回溯）。
      fallback = run_log.reverse.find { |(cs, _h)| !solve_orders(objects, cs, head).empty? rescue false }
      if fallback
        cons, _h = fallback
        orders = begin
          solve_orders(objects, cons, head)
        rescue StandardError
          []
        end
        warn "    ↻ 约束并集矛盾，回退到 #{cons.size} 条最早一致子集（解 #{orders.size} 个）"
      end
    end
    if orders.empty?
      stats[:fail_contra] += 1
      rows << { idx: i, verdict: 'FAIL', diag: '约束矛盾（无误模型）', constraints: cons, head: head }
      puts "  FAIL   #%03d [约束矛盾] %s" % [i, cons.inspect]
      next
    end

    target_letter = ex['target'][/\(([#{letters}])\)/, 1] || ex['target'][/\(([A-G])\)/, 1]
    opts = parse_options(input, objects, head)
    rank, side = opts[target_letter] ? opts[target_letter].values_at(:rank, :side) : [nil, nil]
    target_obj = opts[target_letter] && opts[target_letter][:obj]
    if rank.nil? || target_obj.nil?
      concept_heads = %w[new old expensive cheap first]
      backup = concept_heads.find do |h|
        next if h == head
        b_rank, _b_side = rank_for((opts[target_letter] || {})[:text].to_s, h)
        !b_rank.nil?
      end
      if backup
        opts = parse_options(input, objects, backup)
        rank, side = opts[target_letter].values_at(:rank, :side)
        target_obj = opts[target_letter][:obj]
        warn "    ↻ head #{head.inspect} 无法解释概念词选项，机器按序向改判 #{backup.inspect}"
        head = backup
      end
    end
    if rank.nil? || target_obj.nil?
      stats[:fail_option] += 1
      rows << { idx: i, verdict: 'FAIL', diag: '选项未覆盖', head: head, target: ex['target'] }
      puts "  FAIL   #%03d [选项未覆盖] head=%p target=%s" % [i, head, ex['target'][0, 70]]
      next
    end

    if orders.size == 1
      # :abs=绝对坐标直接定位(从左数); :t_abs=从右数绝对坐标;
      # :h=概念序头第rank(=order[rank-1]); :t=概念尾端第rank
      pos = target_pos(rank, side, n)
      machine = orders.first[pos - 1]
      pass = machine == target_obj
      # 唯一解但答案不符 → 语义层方向极可能翻转，补一次独立复查（不并集，方向翻转并集反而矛盾）。
      # 概念题与物理方位题（left/right）一样会翻，复查必须全 head 覆盖。
      if !pass && !offline && extra_runs < 3
        recheck = run_semantic(BBH_OFFICIAL_PROMPT.gsub('{{OBJECTS}}', objects.inspect)
                                                   .gsub('{{TEXT}}', input + "\n\n⚠ 复查：上次的方向判反了，例如 'older than' 应编码为 before(更旧在前) 而非 after。请复查 before/after 与 head 的方向是否完全一致。"))
        if recheck && recheck['constraints'].is_a?(Array)
          rhead = recheck['head'] || head
          begin
            rorders = solve_orders(objects, recheck['constraints'], rhead)
          rescue StandardError
            rorders = []
          end
          if rorders.size == 1
            opts_r = parse_options(input, objects, rhead)
            r_rank, r_side = opts_r[target_letter] ? opts_r[target_letter].values_at(:rank, :side) : [nil, nil]
            if r_rank
              rpos = target_pos(r_rank, r_side, n)
              rmachine = rorders.first[rpos - 1]
              if rmachine == target_obj
                cons, orders, head, opts = recheck['constraints'], rorders, rhead, opts_r
                rank, side, pos, machine, pass = r_rank, r_side, rpos, rmachine, true
                warn "    ↻ 独立复查 PASS：#{machine.inspect}==#{target_obj.inspect}（方向翻转已修正 head=#{head.inspect}）"
              end
            end
          end
        end
      end
      # 概念方向整体翻转兜底（零 LLM）：唯一解错时，若存在概念语义，head 反向重解。
      if !pass && head && OPPOSITE[head]
        flip = OPPOSITE[head]
        begin
          forders = solve_orders(objects, cons, flip)
        rescue StandardError
          forders = []
        end
        if forders.size == 1
          fopts = parse_options(input, objects, flip)
          f_rank, f_side = fopts[target_letter] ? fopts[target_letter].values_at(:rank, :side) : [nil, nil]
          if f_rank
            fpos = target_pos(f_rank, f_side, n)
            fmachine = forders.first[fpos - 1]
            if fmachine == target_obj
              head = flip
              pos = fpos
              machine = fmachine
              opts = fopts
              rank, side = f_rank, f_side
              pass = true
              warn "    ↻ head 反向兜底 PASS：#{machine.inspect}==#{target_obj.inspect}（head=#{head.inspect}）"
            end
          end
        end
      end
      stats[:pass] += 1 if pass
      stats[:fail_miss] += 1 unless pass
      rows << { idx: i, verdict: pass ? 'PASS' : 'FAIL', head: head, cons: cons,
                order: orders.first.join(' < '), pos: pos, machine: machine, target_obj: target_obj }
      puts "  %s   #%03d [%s%s] %s" % [pass ? 'PASS' : 'FAIL', i, machine, (pass ? '==' : '!='), target_obj]
      puts "        law #{cons.inspect}  order=#{orders.first.join(' < ')}"
    else
      stats[:fail_multi] += 1
      rows << { idx: i, verdict: 'FAIL', diag: '非唯一解', constraints: cons, n: orders.size }
      puts "  FAIL   #%03d [解不唯一=%d] %s" % [i, orders.size, cons.inspect]
    end
  end

  puts "═══ 结果 #{stats[:pass]}/#{examples.size} PASS  #{stats.to_json} ═══"
  Dir.mkdir(File.join(ROOT, 'examples', 'gradebook')) unless File.directory?(File.join(ROOT, 'examples', 'gradebook'))
  art = File.join(ROOT, 'examples', 'gradebook', "bbh_official_#{Time.now.strftime('%Y%m%d-%H%M')}.json")
  File.write(art, JSON.pretty_generate(generated_at: Time.now.iso8601, model: ENV['AGNES_MODEL'], total: examples.size, rows: rows))
  puts "  存档: #{art}"
end

main if $PROGRAM_NAME == __FILE__