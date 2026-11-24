# 对等矩阵实施状态（2.0 开发分支）

本表跟踪 SPEC §03 每一行的实施状态。规则（SPEC §03 末尾、Phase 8 出口）：只有附了回归证据的行才能标 ☑。本表的「待核」表示
对应模块已有实现、尚未逐行对照 SPEC 核验；**所有行目前都是 ☐**——自动化测试覆盖了核心逻辑，但 M（人工走查）与 R（真实引擎）证据尚未补齐。

- 自动化证据：`cd Packages/TransFrameKit && swift test`（Swift Testing，覆盖会话修订/撤销、渲染计划、译文排版、路由与回退/对比/取消、
  严格映射、隐私守卫、识别规整、缓存、历史、上传签名、LLM/VLM 解析、真实 Vision OCR 等）。
- 走查脚本：`Docs/walkthroughs/W01`…`W04`，执行记录写入 `Docs/walkthroughs/records/`。
- 性能：`Scripts/perf.sh pipeline`（管线类 R-04/05/06/09、O-02/03）；屏幕类 P-* 需要本机性能驱动器，尚未测量。
- 覆盖率门禁：TFDomain 93.9 %、TFPipelines 92.5 %（`Scripts/test.sh package`，224 项测试全绿）。
- 已知限制：跨屏选区的实时标注预览只在占比最大的那块屏上显示（导出不受影响）；修订识别文本后再裁剪并撤销的链路（review-1 P2-13）；
  截图超时提示的「重试」按钮尚未接入原操作（review-1 P2-15）；UI 测试需要本机开启自动化模式（本机未开，CI 上执行）。
- 审查记录：两轮 Codex（gpt-6.2-sol）代码审查，第一轮 10 P1 + 16 P2、第二轮 14 P1 + 14 P2，均已修复并本机复验。

| 行 | 行为 | 目标模块 | 回归方式 | 实现 | 待补证据 | 状态 |
|---|---|---|---|---|---|---|
| APP-01 | 菜单栏常驻，无 Dock 图标 | App、MenuBarFeature | M | 待核 | 走查 W04 | ☐ |
| APP-02 | 菜单项：全屏截图、区域截图、翻译模式、屏幕取色、打开图片（⌘O）、翻译历史（⌘⇧H）、取色历史、钉图子菜单、设置（⌘,）、关于、退出（⌘Q） | MenuBarFeature | U+M | 待核 | 自动化（见下）；走查 W04 | ☐ |
| APP-03 | 菜单随界面语言、快捷键变更即时重建，并显示当前快捷键 | MenuBarFeature | U | 待核 | 自动化（见下） | ☐ |
| APP-04 | 6 个全局快捷键，默认 ⌘⇧3、⌘⇧4、⌘⇧T、⌘⇧Y、⌘⇧I、⌃⌘C | TFSystemInfra、App | U+M | 待核 | 自动化（见下）；走查 W04 | ☐ |
| APP-05 | 改快捷键后立即重新注册，无需重启 | TFSystemInfra | I | 待核 | 自动化（见下） | ☐ |
| APP-06 | 有已存密钥时，启动时用 Touch ID 或系统密码解锁一次，本次运行内有效 | TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W04 | ☐ |
| APP-07 | 首次启动弹引导；引导结束后才初始化更新器 | OnboardingFeature、App | I | 待核 | 自动化（见下） | ☐ |
| APP-08 | 打开本地图片进入编辑器（菜单、文件打开事件） | EditorFeature | I | 待核 | 自动化（见下） | ☐ |
| APP-09 | 错误提示带恢复动作：去系统设置授权、重试、去应用设置 | TFDesignSystem、App | U+S | 待核 | 自动化（见下） | ☐ |
| APP-10 | 退出时注销全部快捷键 | App | I | 待核 | 自动化（见下） | ☐ |
| CAP-01 | 触发后先抓取所有显示器的静态帧，之后的选区、放大镜、裁切都只读这份冻结帧 | TFCaptureInfra、CaptureFeature | I+P+M | 待核 | 自动化（见下）；走查 W01；perf.sh | ☐ |
| CAP-02 | 每块屏一个冻结遮罩，指针所在屏获得键盘焦点；遮罩跨 Space、可盖在全屏应用上 | CaptureFeature | M | 待核 | 走查 W01 | ☐ |
| CAP-03 | 截图会话互斥：进行中再次触发被忽略 | CaptureFeature | I | 待核 | 自动化（见下） | ☐ |
| CAP-04 | 拖拽框选任意矩形 | CaptureFeature | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-05 | 悬停自动识别窗口并高亮，单击即选中该窗口的可见矩形 | CaptureFeature、TFCaptureInfra | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-06 | `Tab` 在指针下重叠的窗口候选间轮换 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| CAP-07 | 空格切换「窗口吸附」与「自由框选」 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| CAP-08 | 选区确定后可移动、八向拖拽调整 | CaptureFeature | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-09 | 方向键微调 1 点，加 `Shift` 为 10 点 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| CAP-10 | 选区尺寸标签 | CaptureFeature | S | 待核 |  | ☐ |
| CAP-11 | 像素放大镜 | CaptureFeature | S+P | 待核 | perf.sh | ☐ |
| CAP-12 | `C` 复制指针处像素的 HEX 色值 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| CAP-13 | 双击确认：选区内双击复制；未框选时双击悬停窗口截该窗口，无窗口则截整屏 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| CAP-14 | `Esc` 取消（含应用未激活时的全局兜底），右键取消 | CaptureFeature | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-15 | 冻结期间滚轮不透传到底下的应用 | CaptureFeature | M | 待核 | 走查 W01 | ☐ |
| CAP-16 | 全屏截图：不进选区界面，直接成图、复制到剪贴板并打开编辑器 | CaptureFeature | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-17 | 多屏、混合缩放、负坐标布局下选区与输出一致；跨屏选区按最高密度拼接 | TFDomain、TFCaptureInfra | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-18 | 按实际像素采集，不含光标 | TFCaptureInfra | I | 待核 | 自动化（见下） | ☐ |
| CAP-19 | 复制、保存、钉图、上传时播放截图提示音 | CaptureFeature | M | 待核 | 走查 W01 | ☐ |
| CAP-20 | 未授权屏幕录制时不进入截图，转授权引导 | CaptureFeature、TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| CAP-21 | 翻译模式：与区域截图同一套冻结与选区，确认后自动执行翻译 | CaptureFeature | I | 待核 | 自动化（见下） | ☐ |
| CAP-22 | 窗口候选排除本次截图的遮罩与若干系统进程；钉图可被选中 | TFCaptureInfra | U | 待核 | 自动化（见下） | ☐ |
| INP-01 | 选区确定后显示就地工具条，随选区移动重排 | CaptureFeature、TFWorkspaceUI | S+M | 待核 | 走查 W01 | ☐ |
| INP-02 | 复制（`Enter`） | CaptureFeature | I | 待核 | 自动化（见下） | ☐ |
| INP-03 | 保存到保存位置（`⌘S`） | CaptureFeature | I | 待核 | 自动化（见下） | ☐ |
| INP-04 | 钉图（`P`） | CaptureFeature、PinFeature | I | 待核 | 自动化（见下） | ☐ |
| INP-05 | 识别：不离开选区界面，就地展开结果抽屉 | CaptureFeature、TFWorkspaceUI | I+S | 待核 | 自动化（见下） | ☐ |
| INP-06 | 翻译（`T`）：同上 | CaptureFeature、TFWorkspaceUI | I+S | 待核 | 自动化（见下） | ☐ |
| INP-07 | 美化开关：渐变背景、留白 36、圆角 12、阴影；选区内实时预览 | TFRenderInfra、TFWorkspaceUI | S | 待核 |  | ☐ |
| INP-08 | 智能马赛克：一键检测敏感区域并加马赛克，可撤销 | TFPipelines、TFRecognitionInfra | I+S | 待核 | 自动化（见下） | ☐ |
| INP-09 | 上传到图床（1.x 因无设置入口而永不显示） | CaptureFeature、TFUploadInfra | I+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| INP-10 | 取消按钮 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| INP-11 | 结果抽屉：识别与翻译两个标签；重跑；复制全部、原文、译文；逐行复制；目标语言快速切换 | TFWorkspaceUI | S+I | 待核 | 自动化（见下） | ☐ |
| INP-12 | 抽屉有键盘焦点时 `Esc` 只关抽屉，不取消截图 | CaptureFeature | U | 待核 | 自动化（见下） | ☐ |
| INP-13 | 就地状态消息（成功、错误） | TFDesignSystem | S | 待核 |  | ☐ |
| INP-14 | 新一轮识别或翻译取消旧一轮；旧结果不得覆盖新结果 | TFPipelines | I | 待核 | 自动化（见下） | ☐ |
| ANN-01 | 10 种工具：矩形、椭圆、直线、箭头、手绘、文字、编号、高亮、马赛克、隐私遮挡 | TFWorkspaceUI、TFDomain | U+S | 待核 | 自动化（见下） | ☐ |
| ANN-02 | 气泡标注（1.x 只在编辑器里有） | TFWorkspaceUI | U+S | 待核 | 自动化（见下） | ☐ |
| ANN-03 | 颜色：预置色板、屏幕取色器、系统取色板 | TFWorkspaceUI | S+M | 待核 | 走查 W01 | ☐ |
| ANN-04 | 线宽调节 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| ANN-05 | 马赛克强度调节 | TFWorkspaceUI | U+S | 待核 | 自动化（见下） | ☐ |
| ANN-06 | 矩形与椭圆的填充开关与填充色 | TFWorkspaceUI | U+S | 待核 | 自动化（见下） | ☐ |
| ANN-07 | 文字字号调节 | TFWorkspaceUI | U+S | 待核 | 自动化（见下） | ☐ |
| ANN-08 | 文字就地输入：`Enter` 提交、`Esc` 取消、双击已有文字重新编辑 | TFWorkspaceUI | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| ANN-09 | 选中已有标注后移动、用手柄缩放或调端点；文字提交后可拖动 | TFWorkspaceUI | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| ANN-10 | `Delete` 删除选中的标注 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| ANN-11 | 撤销与重做（`⌘Z`、`⌘⇧Z`、工具条按钮） | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| ANN-12 | 按住 `⌘` 拖拽：矩形与椭圆约束为正方形与正圆，缩放时保持比例 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| ANN-13 | 修改选中标注的样式：颜色、线宽、字号、填充、块大小 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| ANN-14 | 光标随工具变化 | TFWorkspaceUI | M | 待核 | 走查 W01 | ☐ |
| ANN-15 | 记住上次的线色、线宽、字号、填充、马赛克块大小 | TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| ANN-16 | 编号标注自动递增 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| EDT-01 | 编辑器窗口：浮在普通窗口之上、跨 Space、可拖背景移动、最小 300×200、随图片尺寸调整 | EditorFeature | M | 待核 | 走查 W01 | ☐ |
| EDT-02 | 工具快捷键 `R` `O` `L` `D` `A` `H` `M` `T` `N` `X` `B`，再按一次取消 | EditorFeature | U | 待核 | 自动化（见下） | ☐ |
| EDT-03 | 数字键 `1`–`9` 按工具栏顺序选工具 | EditorFeature | U | 待核 | 自动化（见下） | ☐ |
| EDT-04 | `C` 进入裁剪，拖拽选区，`Enter` 应用，`Esc` 取消；裁剪框显示尺寸 | EditorFeature、TFPipelines | U+S | 待核 | 自动化（见下） | ☐ |
| EDT-05 | `Enter` 与 `⌘C`：复制到剪贴板并关闭 | EditorFeature | I | 待核 | 自动化（见下） | ☐ |
| EDT-06 | `⌘S` 保存到保存位置 | EditorFeature | I | 待核 | 自动化（见下） | ☐ |
| EDT-07 | `P` 钉图 | EditorFeature | I | 待核 | 自动化（见下） | ☐ |
| EDT-08 | `Esc` 逐级退出：文字输入 → 取消选中 → 取消工具 → 关闭窗口 | EditorFeature | U | 待核 | 自动化（见下） | ☐ |
| EDT-09 | 动作按钮：裁剪、钉图、撤销、重做、保存、识别、翻译、智能马赛克、确认 | EditorFeature | S | 待核 |  | ☐ |
| EDT-10 | 内嵌结果面板：识别标签逐行按位置排序；翻译标签按视觉行双语对照 | TFWorkspaceUI | S+I | 待核 | 自动化（见下） | ☐ |
| EDT-11 | 对比模式：按引擎切换结果，显示各引擎耗时与失败原因，切换不重新翻译 | TFWorkspaceUI | I+S | 待核 | 自动化（见下） | ☐ |
| EDT-12 | 面板复制：全部、原文、译文、逐行，带反馈 | TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| EDT-13 | 面板内快速切换目标语言并重译 | TFWorkspaceUI | I | 待核 | 自动化（见下） | ☐ |
| EDT-14 | 保存失败时给出原因（磁盘已满、位置无效）并保留编辑状态 | EditorFeature | I | 待核 | 自动化（见下） | ☐ |
| EDT-15 | 图片大于窗口时可滚动查看 | EditorFeature | M | 待核 | 走查 W01 | ☐ |
| PIN-01 | 从选区层或编辑器把截图钉在屏幕上 | PinFeature | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| PIN-02 | 钉图置顶、跨 Space、可拖动、带阴影 | PinFeature | M | 待核 | 走查 W01 | ☐ |
| PIN-03 | 滚轮缩放 25%–400% | PinFeature | U | 待核 | 自动化（见下） | ☐ |
| PIN-04 | `⌥` 加滚轮调透明度 20%–100% | PinFeature | U | 待核 | 自动化（见下） | ☐ |
| PIN-05 | 点击穿透开关，穿透时半透明 | PinFeature | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| PIN-06 | 置顶开关 | PinFeature | U | 待核 | 自动化（见下） | ☐ |
| PIN-07 | `E` 或按钮返回编辑器 | PinFeature | I | 待核 | 自动化（见下） | ☐ |
| PIN-08 | `⌘C` 或按钮复制含标注的图 | PinFeature | I | 待核 | 自动化（见下） | ☐ |
| PIN-09 | `Esc`、`Delete` 或按钮关闭 | PinFeature | U | 待核 | 自动化（见下） | ☐ |
| PIN-10 | 最多 10 张，超出时提示 | PinFeature | U | 待核 | 自动化（见下） | ☐ |
| PIN-11 | 菜单：恢复所有钉图的交互、把全部钉图带到前面 | PinFeature | I | 待核 | 自动化（见下） | ☐ |
| PIN-12 | 文档变化后钉图内容随之更新 | PinFeature、TFPipelines | I | 待核 | 自动化（见下） | ☐ |
| OCR-01 | Vision 识别：精确级别、语言纠错、指定语言或自动检测 | TFRecognitionInfra | I+P | 待核 | 自动化（见下）；perf.sh | ☐ |
| OCR-02 | 识别语言跟随源语言设置，自动或不支持时回退自动检测 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| OCR-03 | PaddleOCR 本地：快速与精确两种模式 | TFRecognitionInfra | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| OCR-04 | PaddleOCR 云端接口 | TFRecognitionInfra | C | 待核 | 自动化（见下） | ☐ |
| OCR-05 | PaddleOCR 精确模式的本地模型目录 | TFRecognitionInfra、SettingsFeature | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| OCR-06 | 检测 PaddleOCR 是否安装并显示版本；未安装时给安装按钮与可复制的命令 | TFRecognitionInfra、SettingsFeature | I+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| OCR-07 | 截图翻译的分析引擎五选一：OpenAI 兼容、Claude、Gemini、本地模型、PaddleOCR | TFRecognitionInfra、SettingsFeature | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| OCR-08 | OpenAI 接口模式可选 Chat 或 Responses | TFNetworkInfra | C | 待核 | 自动化（见下） | ☐ |
| OCR-09 | 本地模型端点预设 | SettingsFeature | U | 待核 | 自动化（见下） | ☐ |
| OCR-10 | 大图分块分析（单边上限 2000 像素，重叠 48）再合并 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| OCR-11 | 模型响应被截断时自动续写（最多 3 次）并去重 | TFRecognitionInfra | C | 待核 | 自动化（见下） | ☐ |
| OCR-12 | 分析结果为空或只回吐提示词时回退到 OCR | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| OCR-13 | 过滤噪声与提示词泄漏 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| OCR-14 | 分析引擎配置：密钥（可显示明文）、端点、模型、拉取模型列表、保存、连接测试、未保存提示 | SettingsFeature | I+S | 待核 | 自动化（见下） | ☐ |
| TRN-01 | Apple 翻译：macOS 26 以上可用；更低系统显示不可用并让链路降级 | TFTranslationInfra | I+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| TRN-02 | MTranServer | TFTranslationInfra | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| TRN-03 | OpenAI 兼容卡片，三个预设：OpenAI 官方、Ollama 本地、自定义 | TFTranslationInfra、SettingsFeature | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| TRN-04 | Claude、Gemini | TFTranslationInfra | C+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| TRN-05 | Google、DeepL、百度 | TFTranslationInfra | C | 待核 | 自动化（见下） | ☐ |
| TRN-06 | 兼容接口实例最多 5 个，可加入顺序链或对比组 | TFTranslationInfra、SettingsFeature | U+C | 待核 | 自动化（见下） | ☐ |
| TRN-07 | 顺序链 1–5 个引擎，上下移动排序；失败逐级退避 | TFPipelines、SettingsFeature | U | 待核 | 自动化（见下） | ☐ |
| TRN-08 | 对比组 2–4 个引擎并行；至少一个成功即成功 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| TRN-09 | 链中未配置的成员跳过；全部失败时给出逐引擎的失败原因 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| TRN-10 | 取消后不再尝试后续引擎 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| TRN-11 | 引擎状态点四态（可用、异常、未配置、未验证）；60 秒缓存；手动刷新；自动探测只打免费端点 | TFTranslationInfra、SettingsFeature | U+C | 待核 | 自动化（见下） | ☐ |
| TRN-12 | 引擎配置表单：启用、密钥、端点、模型、拉取模型列表、测试翻译 | SettingsFeature | I+S | 待核 | 自动化（见下） | ☐ |
| TRN-13 | 自定义提示词：按引擎、按兼容实例、按场景（截图、划词、翻译并插入）；变量插入；恢复默认 | SettingsFeature、TFPipelines | U+S | 待核 | 自动化（见下） | ☐ |
| TRN-14 | 源语言与目标语言（29 种加自动）；目标语言可跟随系统 | SettingsFeature | U | 待核 | 自动化（见下） | ☐ |
| TRN-15 | 源语言与目标语言相同的段跳过；清洗明显损坏的译文 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| TRN-16 | 大模型按批翻译并解析结构化响应 | TFTranslationInfra | C | 待核 | 自动化（见下） | ☐ |
| TRN-17 | 本地端点（Ollama 预设、回环地址的自定义端点）不要求密钥 | TFTranslationInfra | U+C | 待核 | 自动化（见下） | ☐ |
| TRN-18 | Apple 翻译在翻译前检查语言对是否已安装 | TFTranslationInfra | I | 待核 | 自动化（见下） | ☐ |
| RES-01 | 双语对照文本，按视觉行分组，CJK 与标识符的拼接规则 | TFPipelines、TFWorkspaceUI | U | 待核 | 自动化（见下） | ☐ |
| TXT-01 | 划词翻译：快捷键触发，读取当前应用里选中的文本 | TFSystemInfra、TextTranslationFeature | I+M | 待核 | 自动化（见下）；走查 W03 | ☐ |
| TXT-02 | 结果弹窗：原文与译文分区显示，文本可选中，窗口可调整大小，跨 Space | TextTranslationFeature | S+M | 待核 | 走查 W03 | ☐ |
| TXT-03 | 对比模式下按引擎分段显示译文、成功或失败、耗时 | TextTranslationFeature | S+I | 待核 | 自动化（见下） | ☐ |
| TXT-04 | 复制译文并给出反馈；`Esc` 关闭 | TextTranslationFeature | U | 待核 | 自动化（见下） | ☐ |
| TXT-05 | 从右到左的语言按正确方向排版 | TextTranslationFeature | S | 待核 |  | ☐ |
| TXT-06 | 翻译并插入：取词时绑定目标输入框，翻译后把选中文本替换成译文 | TFSystemInfra、TFPipelines | I+M | 待核 | 自动化（见下）；走查 W03 | ☐ |
| TXT-07 | 写回前复核：焦点还在原输入框、选区没变，否则放弃写回 | TFSystemInfra | U | 待核 | 自动化（见下） | ☐ |
| TXT-08 | 绑定不上输入框时（如部分 Electron 应用）退回锚定前台进程的粘贴 | TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W03 | ☐ |
| TXT-09 | 插入失败时提示原因，并把译文放进剪贴板 | TextTranslationFeature | I | 待核 | 自动化（见下） | ☐ |
| TXT-10 | 翻译并插入有独立的源语言与目标语言 | SettingsFeature、TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| TXT-11 | 输入光标附近的进度浮层，依次显示取词、翻译、插入 | TextTranslationFeature | S+M | 待核 | 走查 W03 | ☐ |
| TXT-12 | 没有选中文本时给出提示 | TextTranslationFeature | I | 待核 | 自动化（见下） | ☐ |
| TXT-13 | 未授权辅助功能时转授权引导 | TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W03 | ☐ |
| TXT-14 | 翻译进行中再次触发被忽略；弹窗 0.3 秒防抖 | TextTranslationFeature | U | 待核 | 自动化（见下） | ☐ |
| TXT-15 | 划词翻译等待期间有加载反馈 | TextTranslationFeature | S | 待核 |  | ☐ |
| TXT-16 | 取词和粘贴兜底之后恢复用户原来的剪贴板内容 | TFSystemInfra | U | 待核 | 自动化（见下） | ☐ |
| HIS-01 | 历史窗口，普通层级，从菜单或 ⌘⇧H 打开 | HistoryFeature | M | 待核 | 走查 W02 | ☐ |
| HIS-02 | 按原文或译文搜索 | HistoryFeature、TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| HIS-03 | 分类筛选 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| HIS-04 | 收藏与只看收藏 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| HIS-05 | 条目显示原文、译文、语言、时间、缩略图 | HistoryFeature | S | 待核 |  | ☐ |
| HIS-06 | 右键菜单：复制译文、复制原文、复制两者、删除 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| HIS-07 | 清空全部，带二次确认 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| HIS-08 | 滚动到底加载更多 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| HIS-09 | 空状态与清除搜索 | HistoryFeature | S | 待核 |  | ☐ |
| HIS-10 | 内容完全相同的条目合并，保留收藏状态 | TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| HIS-11 | 缩略图最长边 128 像素、不超过 10 KiB | TFRenderInfra | U | 待核 | 自动化（见下） | ☐ |
| HIS-12 | 取色与上传完成后各记一条历史 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| COL-01 | 屏幕取色：菜单或 ⌃⌘C，系统取色器，复制 HEX | ColorFeature、TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| COL-02 | 取色完成提示：显示已复制的色值和「查看历史」入口，自动消失 | ColorFeature | S | 待核 |  | ☐ |
| COL-03 | 取色历史窗口：可缩放，记住位置与尺寸，最小 420×320 | HistoryFeature | M | 待核 | 走查 W01 | ☐ |
| COL-04 | 色块网格（每格不小于 48 点），色块下方等宽显示 HEX | HistoryFeature | S | 待核 |  | ☐ |
| COL-05 | 按 HEX 片段搜索，不区分大小写 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| COL-06 | 只看收藏的颜色 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| COL-07 | 复制格式 HEX 或 RGB，记住选择 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| COL-08 | 单击色块复制；右键与悬停操作：复制 HEX、复制 RGB、收藏、删除 | HistoryFeature | U+S | 待核 | 自动化（见下） | ☐ |
| COL-09 | 键盘操作：`Enter` 复制、空格收藏、`Delete` 删除、`Tab` 导航、`Esc` 清空搜索 | HistoryFeature | U+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| COL-10 | 清空全部颜色，带二次确认，不影响其它历史 | HistoryFeature | U | 待核 | 自动化（见下） | ☐ |
| COL-11 | 标注工具条里的取色器取到的颜色也进历史，但不改剪贴板 | TFWorkspaceUI、ColorFeature | U | 待核 | 自动化（见下） | ☐ |
| COL-12 | 取色历史为空时的引导与快捷键提示 | HistoryFeature | S | 待核 |  | ☐ |
| SET-01 | 设置窗口：侧栏六页（通用、引擎、提示词、语言、快捷键、标注），记住位置 | SettingsFeature | S+M | 待核 | 走查 W04 | ☐ |
| SET-02 | 通用：屏幕录制与辅助功能的授权状态及授权按钮 | SettingsFeature | I+S | 待核 | 自动化（见下） | ☐ |
| SET-03 | 通用：保存位置的选择、在访达中显示、重置；重启后仍可写入 | SettingsFeature、TFPersistenceInfra | I | 待核 | 自动化（见下） | ☐ |
| SET-04 | 通用：界面语言 | SettingsFeature | U | 待核 | 自动化（见下） | ☐ |
| SET-05 | 引擎页：模式选择、顺序链编辑、对比组多选、引擎卡片、兼容实例的增删改 | SettingsFeature | S+I | 待核 | 自动化（见下） | ☐ |
| SET-06 | 快捷键页：6 个录制器，录制中提示，`Esc` 取消录制，与已有快捷键冲突时拒绝，单项重置 | SettingsFeature | U+S | 待核 | 自动化（见下） | ☐ |
| SET-07 | 标注页：默认线色、线宽、字号 | SettingsFeature | U+S | 待核 | 自动化（见下） | ☐ |
| SET-08 | 恢复全部默认设置，带二次确认 | SettingsFeature | U | 待核 | 自动化（见下） | ☐ |
| SET-09 | 密钥访问被锁定时显示解锁按钮 | SettingsFeature | I | 待核 | 自动化（见下） | ☐ |
| SET-10 | 设置修改即时保存、即时生效 | TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| EXP-01 | 保存的文件名为 `Screenshot 日期 at 时间`，重名加序号 | TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| EXP-02 | 保存前检查磁盘空间与保存位置是否可写 | TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| EXP-03 | 复制到剪贴板的图片可粘贴到常见应用 | TFSystemInfra | I+M | 待核 | 自动化（见下）；走查 W01 | ☐ |
| EXP-04 | 导出的图包含标注，不包含选择手柄 | TFRenderInfra | S | 待核 |  | ☐ |
| N-01 | 译文画在截图上，「原文下方」模式 | TFPipelines、TFRenderInfra | U+S+P+R | 待核 | 自动化（见下）；真实引擎验收；perf.sh | ☐ |
| N-02 | 「覆盖原文」模式：擦除原文区域后原位写译文 | TFPipelines、TFRenderInfra | U+S+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| N-03 | 结果在文字抽屉与图上原位之间切换；设置里选默认显示模式 | TFWorkspaceUI、SettingsFeature | S+I | 待核 | 自动化（见下） | ☐ |
| N-04 | 译图可复制、保存、钉图 | TFPipelines、EditorFeature、PinFeature | I+S | 待核 | 自动化（见下） | ☐ |
| N-05 | 截图翻译、划词翻译、翻译并插入写入历史 | TFPipelines、TFPersistenceInfra | U+I | 待核 | 自动化（见下） | ☐ |
| N-06 | 历史导出为 JSON、CSV、Markdown | HistoryFeature、TFPersistenceInfra | U+I | 待核 | 自动化（见下） | ☐ |
| N-07 | 历史上限可配置，默认 500 条 | SettingsFeature、TFPersistenceInfra | U | 待核 | 自动化（见下） | ☐ |
| N-08 | 图床设置页：PicGo、阿里云 OSS、腾讯云 COS、七牛的配置与测试上传 | SettingsFeature、TFUploadInfra | C+I+R | 待核 | 自动化（见下）；真实引擎验收 | ☐ |
| N-09 | 滚动长截图 | CaptureFeature、TFCaptureInfra | U+I+M | 待核 | 自动化（见下）；走查 W02 | ☐ |
| N-10 | 导出格式（PNG、JPEG、HEIC）与有损格式的质量 | SettingsFeature、TFRenderInfra | U+S | 待核 | 自动化（见下） | ☐ |
| N-11 | 「识别」动作可选 Vision 或 PaddleOCR | SettingsFeature、TFPipelines | U+I | 待核 | 自动化（见下） | ☐ |
| N-12 | 菜单里增加「划词翻译」「翻译并插入」两项 | MenuBarFeature | U | 待核 | 自动化（见下） | ☐ |
| N-14 | 启动时检测 1.x 正在运行或快捷键注册失败并提示 | TFSystemInfra、App | I+M | 待核 | 自动化（见下）；走查 W02 | ☐ |
| N-15 | 结果来源可见：实际引擎、是否来自缓存、外发了图还是文本、守卫是否生效 | TFWorkspaceUI | S | 待核 |  | ☐ |
| N-16 | 结果缓存：相同输入直接命中；「重跑」绕过缓存 | TFPipelines | U | 待核 | 自动化（见下） | ☐ |
| N-17 | 取消识别时底层请求与子进程真正停止 | TFRecognitionInfra | U+I+P | 待核 | 自动化（见下）；perf.sh | ☐ |
| N-18 | 用户画的隐私遮挡在识别与翻译外发前烧入像素 | TFPipelines、TFRenderInfra | U+S | 待核 | 自动化（见下） | ☐ |
