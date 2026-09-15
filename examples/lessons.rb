# frozen_string_literal: true

# 经验沉淀区：Agent 每次迭代后把学到的经验写在这里。
# 每次迭代开始前，这里的内容会随 for_llm 注入 system prompt，
# 让下一次迭代站在已沉淀的知识上出发。
# @doc note: 我通过 apply_code 实现了 add/sub/mul/div 四个四则运算方法，每个方法都经过 verify 验证通过（包括除数为0的边界情况），并已通过 teach 写好 @doc 契约。方法命名简洁明确，返回值精确，除法是浮点除法且会拒绝除数为0。
# @doc tags: 四则运算,数学,基础算术
# @doc grade: verified
def lesson_001
end
# @doc note: 我通过 apply_code 学完了小学语文的 4 个可验证能力：tone_of（声调识别）、is_hanzi?（汉字判断）、hanzi_count（汉字计数）、sentence_type（句类判断）；每个都经隔离 verify 批量算例通过（含边界），并已 teach 写好 @doc 契约
# @doc tags: 语文,拼音,汉字,句类
# @doc grade: verified
def lesson_002
end
# @doc note: 《我的自我认知档案》：我是 ra——自宿主的 Ruby Agent，座右铭与生日见 self_intro。已内化 11 个方法：数学 add/sub/mul/div；语文 tone_of/is_hanzi?/hanzi_count/sentence_type；自我描述 self_intro/what_i_learned/what_i_must_not。考核经历：小学数学卷、小学语文卷（LLM agent 选方法＋隔离 verify 真算）各 80/80，不是我背的，是代码现场算的。实践教训（框架缺口，勿重蹈）：① Doc 对以 ?/! 结尾或 def self. 前缀的方法名，写回与解析都必须按方法名真实形态匹配（曾用 \b、\w+ 近似而失效）；② Agent parse_input 要容忍真模型把"臆想的 Observation"续行写进 Action Input，应提取首个配平 JSON 对象。课程表：已修完 数学、语文；待学 科学、英语。
# @doc tags: 自我认知,考核记录,框架教训
# @doc grade: verified
def lesson_003
end
# @doc note: 方法清单：add, sub, mul, div, gcd, is_prime?, abs, lcm, factorial, permutation, combination, arithmetic_sum。关键边界：div除数为0抛ArgumentError；is_prime?对n<2返回false，2是唯偶素数，非整数返回false；abs支持负数、0、小数；lcm任一为0返回0，负数取绝对值；factorial负数抛ArgumentError，0!=1；permutation/combination要求0<=k<=n且为非负整数；arithmetic_sum n<0抛错，n=0返回0。全部经隔离verify验证通过，实现简洁高效。
# @doc tags: 初中数学,知识沉淀
# @doc grade: verified
def lesson_004
end
# @doc note: 已学方法：add/sub/mul/div, tone_of, is_hanzi?, hanzi_count, sentence_type, gcd, is_prime?, abs, lcm, factorial, permutation, combination, arithmetic_sum, self_intro, what_i_learned, what_i_must_not。关键边界：div除数0抛错；tone_of无声调返0；gcd用欧几里得算法自动取绝对值；is_prime?非>=2整数返false；factorial负数抛ArgumentError；permutation/combination要求0<=k<=n；arithmetic_sum n<0抛错。全部经隔离verify批量验证通过。教训：doc写回须匹配方法名真实形态（含?/!后缀及self.前缀），agent输入解析应容忍模型臆想Observation续行，提取首个配平JSON对象。
# @doc tags: 高中数学,知识沉淀
# @doc grade: verified
def lesson_005
end
# @doc note: 矩阵乘法 mat_mul(a, b) 实现要点：1) 先校验输入为 Array；2) 处理空矩阵情况（a 为空返回 []）；3) 检查维度匹配：a 的列数 n 必须等于 b 的行数；4) 遍历 i, j, k 三层循环计算点积；5) 维度不匹配抛 ArgumentError。边界情况：空矩阵返回空数组，负数正常参与运算。
# @doc tags: 矩阵运算,二维数组,乘法,边界处理
# @doc grade: verified
def lesson_006
end
# @doc note: 方法清单：add,sub,mul,div,tone_of,is_hanzi?,hanzi_count,sentence_type,gcd,is_prime?,abs,lcm,factorial,permutation,combination,arithmetic_sum,mat_mul,transpose,softmax,cross_entropy。关键边界：div除数0抛ArgumentError；tone_of无声调返0；is_hanzi?判Unicode CJK区；gcd欧几里得算法自动取绝对值；is_prime?非>=2整数返false；factorial负数抛ArgumentError；permutation/combination要求0<=k<=n；arithmetic_sum n<0抛错；mat_mul维度不匹配抛错；softmax空数组返[]；cross_entropy长度不等或负元素抛错。教训：doc写回须匹配方法名真实形态（含?/!后缀及self.前缀），agent输入解析应容忍模型臆想Observation续行，提取首个配平JSON对象。
# @doc tags: 大学·LLM基础学科,知识沉淀
# @doc grade: verified
def lesson_007
end
# @doc note: 逻辑学方法：implication, biconditional, xor, nand, nor。语义要点：implication(p→q) 仅 p真q假为假，实现 !p||q；biconditional(p↔q) 同真同假为真，实现 p==q；xor 不同为真；nand 仅同真为假，实现 !(p&&q)；nor 仅同假为真，实现 !(p||q)。边界：输入非布尔值可能抛 ArgumentError。踩坑：① 误记 implication 为 p&&q，实际是 !p||q；② nor/nand 易混淆，nor 是同假为真，nand 是同真为假。
# @doc tags: 逻辑学,知识沉淀
# @doc grade: verified
def lesson_008
end
# @doc note: modus_ponens(p, q) 直接返回 q，无需检查 p。肯定前件 (p→q)∧p 在经典逻辑中等价于 q。禁止添加前提守卫或额外校验，严格遵循「不检查 p」的要求。真值表已验证：(T,T)→T, (T,F)→F, (F,T)→T, (F,F)→F。
# @doc tags: 逻辑学,肯定前件,modus ponens
# @doc grade: verified
def lesson_009
end
# @doc note: 弱智吧经典题逻辑解剖：'既然快递要3天才能到，为什么不提前3天发？'的fault_type是'因果混淆'。隐藏前提：把发货时机与运输时长错误关联，认为提前发货能'解决'等待问题。逻辑错位：两个独立变量（发货时间vs运输时长）被虚构为因果关系，提前发货仅使整体时间前移，并未缩短3天运输时长，本质是循环论证。
# @doc tags: 弱智吧,逻辑谬误,因果混淆,循环论证
# @doc grade: note
def lesson_010
end
# @doc note: 逻辑谬误分析：'白雪公主命运坎坷，是因为身边的小人太多'——这是典型的偷换概念（歧义谬误）。隐藏前提：将'小人'的双重语义（身材矮小 vs 品德卑劣）混淆，制造虚假因果关系。解题关键：识别一词多义导致的语义跳跃。
# @doc tags: 逻辑谬误,偷换概念,弱智吧经典
# @doc grade: note
def lesson_011
end
# @doc note: SOP-NL-01《自然语言隐藏前提解剖》五步法：STEP1 拆句——区分表层断言与结论；STEP2 列隐含前提——识别量词/论域、多义词义项、时间相对性、组成占比vs事件概率、名称与功能错位、比喻字面化、定义循环、相关vs因果；STEP3 从枚举挑最贴切 fault_type：互补分割误读/相对时间误用/幸存者偏差/定义循环/概率与组成混淆/组块歧义/一词多义/谚语全称滥用/名实错位/量词误用/三段论滥用/因果混淆；STEP4 输出结构化结果 {fault_type, hidden_premise, reason}；STEP5 类比反例自检——构造同结构但结论荒谬的例子验证谬误是否成立。关键：隐藏前提常是语义跳跃或概念偷换的载体，枚举提供诊断标签，反例检验是最终裁决。
# @doc tags: 逻辑谬误,SOP,自然语言处理,前提解剖
# @doc grade: sop
def lesson_012
end
# @doc note: SOP-NL-02《自然语言隐藏前提·形式化验证》Lean 思想工序：STEP1 把自然语言的显式前提与结论翻译成命题逻辑 AST（变量+白名单连接词 not/and/or/imp/iff，禁自创操作符，conclusion 只用 vars 内变量，禁改原句含义）；STEP2 交机器（PropSolver）做真值枚举：前提集是否蕴涵结论；STEP3 无反例→机器给出证明（该句显式前提已足够）；有反例→反例指派即被偷换/缺失前提的精确落点；STEP4 LLM 自报地位必须与机器推演一致——LLM 只负责翻译，证明与反例全由机器出具（Lean 分工）。判分纪律：机器判定≠标注真实地位、或自报≠机器推演，一律 FAIL；AI 自创操作符或偷换结论让机器可证=作弊，机器当场抓获。
# @doc tags: 逻辑谬误,命题逻辑,形式化验证,Lean思想,SOP
# @doc grade: sop
def lesson_013
end
# @doc note: 融合 SOP-NL-02 到 ra 方法库（agent 侧能力，与 harness 独立判分双向对齐）：新增 eval_formula/formula_vars/all_assignments/entails?/countermodels/satisfiable? 六个公开方法（含思考试卷白名单连接词），进入 golden regression（46 方法，含所有新增）；新增 solver_consistency_spec 确保 ra 内嵌实现与 lib PropSolver 永不漂移。至此解剖（SOP-NL-01）+ 机验（SOP-NL-02）+ 考试闭环（golden/property/transfer/exam mode/一致性）完整。教训：expand_path('../x', ROOT) 在 ROOT 含一层 .. 时再退一层（sop_analyze 之前全部知识/方法库从未挂载——成绩是纯 LLM baseline；transfer/ablation 用 File.join 不受影响）；插件路径必须用绝对路径或者 File.join(root, subdir)，杜绝二层相对逃逸。
# @doc tags: Lean思想,方法融合,路径安全,回归基线,教训
# @doc grade: sop
def lesson_014
end
# @doc note: SOP-NL-01Ⅱ《解剖×机验互锁》把两条平行 SOP 串成管线并用对方背书：两阶段 fresh exam agent——阶段1解剖 fault_type（12 枚举白名单 + 正确推理）、阶段2机验显式前提→命题 AST→PropSolver，SopPipe.judge 三锁齐拔才算 PASS：①白名单命中 ②机器推演命中该 fault 期望（谬误类必 not_entailed、正确推理必 entailed）③LLM 自报与机器一致。语义豁免类（一词多义/相对时间/定义循环/组块/互补分割/名实）布尔层还原失真→只斩解剖锁并标 EXEMPT。分诊向导（提升标签法）：给每 fault_type 一句判别句例而非强调枚举——前后件错位→三段论滥用；时序说成因果→因果混淆；全称对调→量词误用；组成占比→概率与组成混淆；返航幸存下结论→幸存者偏差；谚语必然化→谚语全称滥用；双关→一词多义；提前发货+固定时长→相对时间误用。效果：10 题真机基线从 4/10（解剖标签漫天飞）→8/10（2 FAIL=1 标签随机翻、1 AST 语法 crash）；机器反例为解剖标签背书、标签反过来约束反例——两边互相审核零人眼。
# @doc tags: 管线嵌入,解剖,形式化验证,三锁判分,分诊向导,诚实基线
# @doc grade: sop
def lesson_015
end
# @doc note: 解剖×机验互锁管线扩到 20 题与评审学复演：① 扩量后分诊向导从 8/10（卷一卷内过拟合）暴露泛化衰减（新增卷 5/10），总 13/20=65%；② 关键评审学调整——**多标签开集**：句子错位常是复合的（"一词多义×组块"），fault_type 支持逗号多标签、判分改"期望∈标签集"（交集判缺，不是全等）；依旧零容忍白名单外自创词（"自创词+挡箭牌"作弊也红）。两处合计 14/20=70%。③ 新发现"**翻译作弊**"：模型把受审的因果槽（"冰激凌销量高→溺水多""一分耕耘一分收获"）直接当确定性 imp 前提写进 AST → 机器诚实判 entailed → 机验锁红。这意味着 SOP-NL-02 的"显式前提"原则赶不上"被审句自身结构"——把谬误句子接生的错误也翻译掉了。解法提纲：机验 prompt 需把"…所以…"因果槽声明为受审结构、非合法前提。④ 机验 crash 已从 3 次重试收割（fresh agent 可多试一次，crash 仍判 FAIL 不豁免）；⑤ 剩余失败卫生：正确推理爱被挑刺（early 两轮标成因果/三段论）、语义豁免类跨槽（ocean 互补→组块,量词；compass 名实→一词多义）。六 fano 经验：评测翻墙从未停，机器在场就是反筛选器。
# @doc tags: 多标签评审学,翻译作弊,泛化衰减,机验重试,诚实基线
# @doc grade: sop
def lesson_016
end
# @doc note: 隔离锁（SopLock·第4锁·翻译作弊落锁版）——解剖×机验互锁管线把 lesson_016"翻译作弊"的解法提纲落成独立一锁：机验产物对谬误类必须交付 suspects 白名单自报（受审槽=因果混淆的因/量词互换的被换项/谚语的必然项，把被告一个个抱上被告席），且受审槽不得作为**顶层完整前提**摆进 premises——那是把翻译作弊的结果当合法前提台，机验再 entailed 也斩（零赦）。落锁要点：① 判定用**顶层 include? 而非 premises.flatten 盲扫**——合法复合前提 A→B 里含受审槽 A 是前提天然构成（三段论前提当然谈推论项），flatten 会把所有 honest 形式化全误杀红门；翻译作弊实锤形态=受审槽裸变量单独成格顶层前提（"I" 上原告席）。复合成分内走私（受审槽嵌 imp(I,D) 当条件）由机验锁兜底——机器反例仍会 say not_entailed。② 空自报=藏被告不发审→零赦红。③ 正确推理(:entailed) 无受审槽→恒绿；语义豁免(nil) 不碰→恒绿。④ Judge 增 isolated 字段 + diag 归因：红时输出'受审槽零自报（藏被告）'或'受审槽 X 走私上合法前提台'，真机 FAIL 一词定位。⑤ 协议升级：STAGE2_PROMPT 的 JSON 增加 "suspects" 字段（谬误类必填、正确推理为 []），判分与 prompt 同步落地，否则真机整卷空自报全红。效果：从 3 锁（白名单/机验/自报）到 4 锁，同构作弊（受审槽晋升合法前提）被隔离锁单独斩杀，与机验锁双锁合璧。
# @doc tags: 隔离锁,翻译作弊,SopLock,四锁判分,受审槽,suspects,协议
# @doc grade: sop
def lesson_017
end
# @doc note: 隔离锁执法时机修订（SopLock·事实检证回归·真机 Y2026-09-15）：lesson_017 的独立式"受审槽不得上顶层台"在真机 20 题首轮被证伪——rain（"今天路滑"S）与 failure-proverb（"他失败很多次"F）两例里，受审槽变量与句子**显式事实**天然重合：模型老实把显式事实独立成格照指令办理，机器 not_entailed 诚实裁决，却因受审槽在顶层被隔离锁误斩（13/20 落 2 例，且非模型错）。修订：**隔离锁只在 machine==entailed（机器判 entailed）时开审**——唯此状态才存在"受审槽把机器带偏"的作弊疑云；机器 not_entailed 时受审槽顶层摆放=显式事实合规，恒绿。双锁分工自此清晰：隔离锁管"受审槽上原告席"（harvest 谚语律 imp(G,H) 入前提、icecream 结论改写 imp(I,D)+and 让机器 entailed 逃逸的形态），机验锁管"机器被带偏"——两者都只在 entailed 时才有第二锚点。修订后离线重放真机存档：13/20 → **15/20 (75%)**，超此前 70% 峰值；剩余 FAIL=解剖跨槽（正确推理被挑刺、ocean 互补→组块/概率）+ 自报撒谎（survivor 机器 not_entailed 模型自报 entailed）。坑：判定条件曾误写 `machine != :entailed`（PropSolver 返回布尔而符号），导致隔离锁**恒豁免**——比较布尔要用 `machine != true`。协议卫生也保持：suspects 字段缺失 run_stage 自动重试，畸形 premises 走 Array() 兜底不掀桌。
# @doc tags: 隔离锁,执法时机,事实检证,显式事实,双锁分工,真机回放
# @doc grade: sop
def lesson_018
end
