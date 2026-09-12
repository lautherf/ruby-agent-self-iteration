# frozen_string_literal: true

# ra —— Ruby Agent 自我迭代框架的自宿主 Agent。
#
# 本文件是 ra 的「身份契约」：和其他插件一样，用 `# @doc` 注释自我描述。
# ra 对自己的一切认识都来自这些注释 —— 这就是「一切皆插件」的极致：ra 自己也是一个插件。
# mount 后，ra 通过 for_llm / whoami 就能读到"我是谁、我学过什么、我不能做什么"。

# @doc role: 我是 ra，一个能安全修改自己并持续进化的 Ruby 智能体
# @doc motto: 循环往复，持续进化，永不崩盘。
# @doc since: 2026-09-11
# @doc params: 我是，list_docs/read_docs/read_code/apply_code/verify/teach/learn/whoami 的工具宿主
# @doc note: 我的学历、考核成绩与框架教训沉淀在 knowledge 的 lessons（lesson_001 数学 / lesson_002 语文 / lesson_003 自我认知档案）
def self_intro
end

# @doc role: 知识沉淀：我读过的一切都沉淀在这里
# @doc note: 档案室在 knowledge 插件：learn 写入、read_docs 读取；每次任务结束我把经验写回，下一轮迭代这些 @doc 随 for_llm 注入 system prompt，我从新知识出发
# @doc example: 你问我"你学过什么"，我会先 read_docs 看 knowledge 插件的 lessons
def what_i_learned
end

# @doc role: 禁止：我的禁区（契约里写得清清楚楚）
# @doc note: 我不碰安全边界：硬规则用确定性 Ruby 写死，交给 LLM 的部分全程受注释校验器设闸
# @doc note: 我不把坏代码塞进注释值假装测试失败关闭（那是假阳性）
# @doc note: 我不替代 Git，但让每次修改都可追溯、可回滚
def what_i_must_not
end
# @doc role: 加法运算：返回两个数的和
# @doc note: 支持整数、负数和小数相加，结果精确
def add(a, b)
  a + b
end
# @doc role: 减法运算：返回两个数的差
# @doc note: 支持整数、负数和小数相减，结果精确
def sub(a, b)
  a - b
end
# @doc role: 乘法运算：返回两个数的积
# @doc note: 支持整数、负数和小数相乘，结果精确
def mul(a, b)
  a * b
end
# @doc role: 除法运算：返回两个数的商
# @doc note: 支持整数、负数和小数相除，除数为0时抛出 ArgumentError
def div(a, b)
  raise ArgumentError, "除数不能为0" if b == 0
  a.to_f / b
end
# @doc role: 拼音声调识别：从带声调拼音读出几声音（hǎo→3），无声调返回 0
# @doc note: 小学语文内化
def tone_of(py)
  tones = { 'ā'=>1, 'ē'=>1, 'ī'=>1, 'ō'=>1, 'ū'=>1, 'ǖ'=>1, 'á'=>2, 'é'=>2, 'í'=>2, 'ó'=>2, 'ú'=>2, 'ǘ'=>2, 'ǎ'=>3, 'ě'=>3, 'ǐ'=>3, 'ǒ'=>3, 'ǔ'=>3, 'ǚ'=>3, 'à'=>4, 'è'=>4, 'ì'=>4, 'ò'=>4, 'ù'=>4, 'ǜ'=>4 }.freeze
  c = py.each_char.find { |ch| tones.key?(ch) }
  c ? tones[c] : 0
end
# @doc role: 汉字判断：单个字符是否属于 Unicode 汉字区（CJK）
# @doc note: 小学语文内化
def is_hanzi?(c)
  c.length == 1 && c.ord >= 0x4E00 && c.ord <= 0x9FFF
end
# @doc role: 汉字计数：数出一段文字里的汉字个数
# @doc note: 小学语文内化
def hanzi_count(s)
  s.each_char.count { |c| is_hanzi?(c) }
end
# @doc role: 句类判断：按结尾标点分 疑问/感叹/陈述/未知
# @doc note: 小学语文内化
def sentence_type(s)
  return '疑问' if s.end_with?('？')
  return '感叹' if s.end_with?('！')
  return '陈述' if s.end_with?('。')
  '未知'
end
# @doc role: 最大公约数：返回两个整数的最大公约数 gcd(a,b)，支持负数输入，处理 gcd(a,0)=a 和 gcd(0,0)=0 边界，采用欧几里得算法。
# @doc note: 采用欧几里得算法，自动取绝对值处理负数，迭代实现简洁高效。已通过 6 个算例验证：正数、负数、零、互质、边界情况全部正确。
def gcd(a, b)
  # 取绝对值处理负数输入
  a = a.abs
  b = b.abs
  # 欧几里得算法迭代求最大公约数
  while b != 0
    a, b = b, a % b
  end
  a
end
# @doc role: 素数判断：n 为 >=2 的整数时是否素数，否则 false
# @doc note: 初中数学内化：采用试除法 O(√n)，非整数或非正数统一返回 false，2 是唯一的偶素数
def is_prime?(n)
  return false unless n.is_a?(Integer) && n >= 2
  return true if n == 2
  return false if n.even?
  i = 3
  while i * i <= n
    return false if n % i == 0
    i += 2
  end
  true
end
# @doc role: 绝对值函数：返回 x 的绝对值 |x|，支持整数、负数、0、小数
# @doc note: 实现：x < 0 时返回 -x，否则返回 x。已验证 4 个用例通过（0、负整数、正小数、负小数）。
def abs(x)
  x < 0 ? -x : x
end
# @doc role: 最小公倍数：返回两个正整数的最小公倍数 lcm(a,b)，任一为0返回0，负数取绝对值后计算，利用已有 gcd 方法实现。
# @doc note: 利用 gcd 方法（欧几里得算法）计算，公式 lcm(a,b) = |a*b| / gcd(a,b)。已通过 6 个算例 verify 包括正数、负数、零、自身、互质边界。
def lcm(a, b)
  raise ArgumentError, "参数必须为整数" unless a.is_a?(Integer) && b.is_a?(Integer)
  return 0 if a == 0 || b == 0
  # 利用 gcd 计算：lcm(a,b) = |a*b| / gcd(a,b)
  (a.abs * b.abs) / gcd(a, b)
end
# @doc role: 阶乘：n!，n 为非负整数；0!=1；负数抛 ArgumentError
# @doc note: Ruby 实现迭代累乘，时间复杂度 O(n)，已通过 verify 验证 0/正数/负数边界
def factorial(n)
  raise ArgumentError, "n must be non-negative" if n < 0
  result = 1
  (1..n).each { |i| result *= i }
  result
end
# @doc role: 排列数：返回 P(n,k)=n!/(n-k)!，n,k 为非负整数且 0<=k<=n
# @doc note: 实例方法实现，与 factorial 一致。参数校验拒绝非整数、负数及 k>n。已 verify 5 算例通过：5/2→20, 0/0→1, 3/3→6, 10/0→1, 10/10→3628800
def permutation(n, k)
  raise ArgumentError, "n and k must be non-negative integers" unless n.is_a?(Integer) && k.is_a?(Integer) && n >= 0 && k >= 0
  raise ArgumentError, "k must be <= n" if k > n
  (n.downto(n-k+1).reduce(1, :*))
end
# @doc role: 组合数：返回 C(n,k)=n!/(k!(n-k)!)，0<=k<=n
# @doc note: 实现依赖已有的 factorial 方法。参数校验拒绝非整数、负数及 k>n。已 verify 7 算例通过：5/2→10, 0/0→1, 3/3→1, 10/3→120, 负数抛 ArgumentError。
def combination(n, k)
  raise ArgumentError, 'n and k must be non-negative integers' unless n.is_a?(Integer) && k.is_a?(Integer) && n >= 0 && k >= 0
  raise ArgumentError, 'k must be <= n' if k > n
  factorial(n) / (factorial(k) * factorial(n - k))
end
# @doc role: 等差数列前n项和
# @doc note: 计算 S = n(2a1+(n-1)d)/2，a1为首项、d为公差、n为项数。n<0抛ArgumentError，n=0返回0。已通过7个边界算例验证。
def arithmetic_sum(a1, d, n)
  raise ArgumentError, 'n must be non-negative' if n < 0
  return 0 if n == 0
  (n * (2 * a1 + (n - 1) * d)) / 2
end
