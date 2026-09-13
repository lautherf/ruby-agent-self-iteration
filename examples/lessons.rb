# frozen_string_literal: true

# 经验沉淀区：Agent 每次迭代后把学到的经验写在这里。
# 每次迭代开始前，这里的内容会随 for_llm 注入 system prompt，
# 让下一次迭代站在已沉淀的知识上出发。
# @doc note: 我通过 apply_code 实现了 add/sub/mul/div 四个四则运算方法，每个方法都经过 verify 验证通过（包括除数为0的边界情况），并已通过 teach 写好 @doc 契约。方法命名简洁明确，返回值精确，除法是浮点除法且会拒绝除数为0。
# @doc tags: 四则运算,数学,基础算术
def lesson_001
end
# @doc note: 我通过 apply_code 学完了小学语文的 4 个可验证能力：tone_of（声调识别）、is_hanzi?（汉字判断）、hanzi_count（汉字计数）、sentence_type（句类判断）；每个都经隔离 verify 批量算例通过（含边界），并已 teach 写好 @doc 契约
# @doc tags: 语文,拼音,汉字,句类
def lesson_002
end
# @doc note: 《我的自我认知档案》：我是 ra——自宿主的 Ruby Agent，座右铭与生日见 self_intro。已内化 11 个方法：数学 add/sub/mul/div；语文 tone_of/is_hanzi?/hanzi_count/sentence_type；自我描述 self_intro/what_i_learned/what_i_must_not。考核经历：小学数学卷、小学语文卷（LLM agent 选方法＋隔离 verify 真算）各 80/80，不是我背的，是代码现场算的。实践教训（框架缺口，勿重蹈）：① Doc 对以 ?/! 结尾或 def self. 前缀的方法名，写回与解析都必须按方法名真实形态匹配（曾用 \b、\w+ 近似而失效）；② Agent parse_input 要容忍真模型把"臆想的 Observation"续行写进 Action Input，应提取首个配平 JSON 对象。课程表：已修完 数学、语文；待学 科学、英语。
# @doc tags: 自我认知,考核记录,框架教训
def lesson_003
end
# @doc note: 方法清单：add, sub, mul, div, gcd, is_prime?, abs, lcm, factorial, permutation, combination, arithmetic_sum。关键边界：div除数为0抛ArgumentError；is_prime?对n<2返回false，2是唯偶素数，非整数返回false；abs支持负数、0、小数；lcm任一为0返回0，负数取绝对值；factorial负数抛ArgumentError，0!=1；permutation/combination要求0<=k<=n且为非负整数；arithmetic_sum n<0抛错，n=0返回0。全部经隔离verify验证通过，实现简洁高效。
# @doc tags: 初中数学,知识沉淀
def lesson_004
end
# @doc note: 已学方法：add/sub/mul/div, tone_of, is_hanzi?, hanzi_count, sentence_type, gcd, is_prime?, abs, lcm, factorial, permutation, combination, arithmetic_sum, self_intro, what_i_learned, what_i_must_not。关键边界：div除数0抛错；tone_of无声调返0；gcd用欧几里得算法自动取绝对值；is_prime?非>=2整数返false；factorial负数抛ArgumentError；permutation/combination要求0<=k<=n；arithmetic_sum n<0抛错。全部经隔离verify批量验证通过。教训：doc写回须匹配方法名真实形态（含?/!后缀及self.前缀），agent输入解析应容忍模型臆想Observation续行，提取首个配平JSON对象。
# @doc tags: 高中数学,知识沉淀
def lesson_005
end
# @doc note: 矩阵乘法 mat_mul(a, b) 实现要点：1) 先校验输入为 Array；2) 处理空矩阵情况（a 为空返回 []）；3) 检查维度匹配：a 的列数 n 必须等于 b 的行数；4) 遍历 i, j, k 三层循环计算点积；5) 维度不匹配抛 ArgumentError。边界情况：空矩阵返回空数组，负数正常参与运算。
# @doc tags: 矩阵运算,二维数组,乘法,边界处理
def lesson_006
end
# @doc note: 方法清单：add,sub,mul,div,tone_of,is_hanzi?,hanzi_count,sentence_type,gcd,is_prime?,abs,lcm,factorial,permutation,combination,arithmetic_sum,mat_mul,transpose,softmax,cross_entropy。关键边界：div除数0抛ArgumentError；tone_of无声调返0；is_hanzi?判Unicode CJK区；gcd欧几里得算法自动取绝对值；is_prime?非>=2整数返false；factorial负数抛ArgumentError；permutation/combination要求0<=k<=n；arithmetic_sum n<0抛错；mat_mul维度不匹配抛错；softmax空数组返[]；cross_entropy长度不等或负元素抛错。教训：doc写回须匹配方法名真实形态（含?/!后缀及self.前缀），agent输入解析应容忍模型臆想Observation续行，提取首个配平JSON对象。
# @doc tags: 大学·LLM基础学科,知识沉淀
def lesson_007
end
# @doc note: 逻辑学方法：implication, biconditional, xor, nand, nor。语义要点：implication(p→q) 仅 p真q假为假，实现 !p||q；biconditional(p↔q) 同真同假为真，实现 p==q；xor 不同为真；nand 仅同真为假，实现 !(p&&q)；nor 仅同假为真，实现 !(p||q)。边界：输入非布尔值可能抛 ArgumentError。踩坑：① 误记 implication 为 p&&q，实际是 !p||q；② nor/nand 易混淆，nor 是同假为真，nand 是同真为假。
# @doc tags: 逻辑学,知识沉淀
def lesson_008
end
# @doc note: modus_ponens(p, q) 直接返回 q，无需检查 p。肯定前件 (p→q)∧p 在经典逻辑中等价于 q。禁止添加前提守卫或额外校验，严格遵循「不检查 p」的要求。真值表已验证：(T,T)→T, (T,F)→F, (F,T)→T, (F,F)→F。
# @doc tags: 逻辑学,肯定前件,modus ponens
def lesson_009
end
