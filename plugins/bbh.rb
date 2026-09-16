# frozen_string_literal: true

# bbh —— BBH·logical_deduction 的降维机层（降维 = 排列枚举穷举验证）。
#
# 语义层（AgentLoop exam 模式）把自然语言排序句升维成谓词白名单（before/after/adjacent/
# between/rank），本插件做**机器层**：不需要 LLM，纯确定性 Ruby —— 解析对象清单、
# 把选项谓词化、按 head 方向计算 rank 目标位、然后 n! 排列枚举碰唯一解、校验谓词。
#
# 与 examples/bbh_official.rb 保持同步（那是 shell-out 真机脚本，这里是可被
# read_code/apply_code/verify 自改的插件形态）。所有方法都是纯函数，ideas 自持：
#   solve_orders(names, constraints, head) -> [order...]  唯一解 / 多解 / 空（矛盾）
#   satisfies?(order, c, head)         单条谓词在唯一全序下是否为真
#   rank_for(body, head)              选项文字 → [第k, 方位(:abs/:t_abs/:h/:t)]
#   target_pos(rank, side, n)          谓词方位 → 绝对下标（1-based）
#   parse_options(input, objects, head) 选项 → {letter => {obj, rank, side}}
#   objlist_from(input)                题干 → 对象清单
#   normalize_arg(arg, names)          无冠词短名 → 规范全名
#
# 维护者注意：这些方法是 RA 自我迭代的靶子——改动必须配 verify + 回归，见
# examples/bbh_self_iterate.rb。

# @doc role: BBH·logical_deduction 降维机层：纯确定性排序求解，无 LLM 依赖
# @doc note: 谓词白名单 before/after/adjacent/between/rank；排列枚举 n! 碰唯一解，
#   唯一解校验才判 PASS，多解/空解（矛盾）同为 FAIL。语义层输出 JSON 由外部 AgentLoop 解析后送入。
def bbh_intro
end

ORDINAL = { 'first' => 1, 'second' => 2, 'third' => 3, 'fourth' => 4,
            'fifth' => 5, 'sixth' => 6, 'seventh' => 7 }.freeze

ARTICLE = ->(s) { s.sub(/\A(a|an|the)\s+/i, '') }

OPPOSITE = { 'new' => 'old', 'old' => 'new', 'expensive' => 'cheap', 'cheap' => 'expensive',
             'first' => 'last', 'last' => 'first', 'left' => 'right', 'right' => 'left' }.freeze

# @doc role: 题干 → 对象清单（逗号 / and 分隔的短语列表）
# @doc example: objlist_from("set of three objects described as follows: a red book, a blue book, and a green book.") #=> ["a red book","a blue book","a green book"]
def objlist_from(input)
  m = input.match(/:\s*(.+?)(?:\.\s*(?=[A-Z])|\.$)/)
  raw = m && m[1]
  raw = nil if raw && !raw.include?(',')
  return [] unless raw

  raw.split(/,|\band\b/).map(&:strip).reject(&:empty?).map { |s| s.sub(/^and\s*/i, '').strip }
end

# @doc role: 从题干探测对象数（set of three/five/seven objects；缺省 3）
# @doc example: object_count("set of seven objects described as follows: ...") #=> 7
def object_count(input)
  m = input.match(/set of (three|five|seven) objects/)
  m ? { 'three' => 3, 'five' => 5, 'seven' => 7 }.fetch(m[1], 3) : 3
end

# @doc role: 按对象数生成选项字母串（3→ABC，5→ABCDE，7→ABCDEFG）
# @doc example: letters_for(5) #=> "ABCDE"
def letters_for(n)
  ('A'..).take(n == 5 ? 5 : n == 7 ? 7 : 3).join
end

# @doc role: 选项文字 → [第k, 方位]；head 声明概念序向（new/old/expensive/cheap/first）
# @doc note: 物理方位（leftmost/rightmost/from the left/right）是绝对坐标 :abs/:t_abs 不依赖 head；
#   概念词（newest/oldest/most expensive/…）依赖 head：head=头端词。⚠ 序数检查必须先于单数
#   （"second-oldest" 含 "oldest" 子串，反序会误判 rank1）。定位不了返回 [nil, nil]。
# @doc example: rank_for("a red book is the second from the left", "left") #=> [2, :abs]
# @doc example: rank_for("a red book is the oldest", "old") #=> [1, :h]
def rank_for(body, _head)
  return [1, :abs] if body[/leftmost/]
  return [1, :t_abs] if body[/rightmost/]

  if (m = body.match(/the\s+(#{ORDINAL.keys.join('|')})\s+from the\s+(left|right)/))
    return [ORDINAL.fetch(m[1]), m[2] == 'left' ? :abs : :t_abs]
  end
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
  when 'first'
    if (m = body.match(/finished\s+(#{ORDINAL.keys.join('|')}|last)/))
      return [ORDINAL.fetch(m[1], 1), m[1] == 'last' ? :t : :h]
    end
    return [1, :h] if body[/finished (?:top|first)/]
    return [1, :t] if body[/finished (?:bottom|last)/]
  end
  [nil, nil]
end

# @doc role: 谓词方位 → 绝对下标（1-based）
# @doc example: target_pos(2, :t_abs, 5) #=> 4（从右数第 2 = 左起第 4）
# @doc example: target_pos(3, :h, 7) #=> 3（概念头端第 3）
# @doc note: :abs/:h = rank 原样；:t_abs/:t = n - rank + 1（从另一端倒推）。
def target_pos(rank, side, n)
  case side
  when :abs then rank
  when :h then rank
  when :t_abs then n - rank + 1
  when :t then n - rank + 1
  else rank
  end
end

# @doc role: 选项块 → {letter => {obj, rank, side, text}}（对象文字带冠词正则回配）
# @doc note: 选项文字形如 "(A) The red book is the oldest"；对象回配用 无冠词核心词 正则，
#   支持带 the 前缀变体；rank_for 抽不出时 rank/side 为 nil，调用方按 head 改判或判 fail_option。
def parse_options(input, objects, head)
  opts_txt = input[/Options:\n(.*)/m, 1].to_s
  out = {}
  n = objects.size
  letters = letters_for(n)
  core = ->(s) { s.sub(/\A(a|an|the)\s+/i, '') }
  opts_txt.scan(/\(([#{letters}])\)\s*(The\s*)?(.+?)(?=\n\([#{letters}]\)|\z)/) do |letter, _the, body|
    body = body.strip
    obj = objects.find { |o| body.match?(/(?:\bthe\s+)?#{Regexp.escape(core.call(o))}\b/i) }
    rank, side = rank_for(body, head)
    out[letter] = { obj: obj, rank: rank, side: side, text: body }
  end
  out
end

# @doc role: 全序中对象的下标（1-based）
# @doc example: idx(%w[a b c], "b") #=> 2
def idx(order, x)
  order.index(x) + 1
end

# @doc role: 无冠词短参数 → 规范全名（整名相等 → 无冠词核心词相等 → 单词落入）
# @doc example: normalize_arg("red book", ["a red book","a blue book"]) #=> "a red book"
# @doc example: normalize_arg("an orange book", ["a orange book"]) #=> "a orange book"
def normalize_arg(arg, names)
  return arg if names.include?(arg)
  hit = names.find { |n| ARTICLE.call(n) == ARTICLE.call(arg) }
  hit ||= names.find { |n| n.split.include?(ARTICLE.call(arg)) }
  hit || arg
end

# @doc role: 全序排列枚举：返回满足全部约束的所有排列（n! 穷举，0/1/N 个）
# @doc example: solve_orders(%w[a b c], [["before","a","b"]], "left") #=> 3 个排列
# @doc note: 约束串先经 normalize_arg 归一；引用未申报对象会抛错（防语义层瞎编对象名）。
#   head 只影响 rank 谓词的方位定位，before/after/adjacent/between 纯相对。
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

# @doc role: 单条谓词在唯一全序下是否为真
# @doc example: satisfies?(%w[a b c], ["before","a","b"], "left") #=> true
# @doc example: satisfies?(%w[a b c], ["adjacent","a","c"], "left") #=> false（a 与 c 中间隔了 b）
# @doc note: rank 谓词方位解析：物理 (left=左起第k / right=右起第k)；概念端用 head 比对：
#   side==head → 第 k（序头端）；OPPOSITE[side]==head → n-k+1（尾端）。无法定位抛错。
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
  when 'rank'
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
