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
