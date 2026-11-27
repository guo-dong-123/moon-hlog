# MoonHlog 后续路线图

基线为 v0.2.0，提交 `88d9967`。目前已支持 V2 压缩整数 `.hlog` 的读写、按标签和相对时间窗口比较、P99 阈值及 JSON 输出。GitHub Release 提供 Linux x86-64 和 macOS Apple Silicon CLI。CI 已验证四个 MoonBit 后端、Java 互操作和独立模块接入。[发布页](https://github.com/guo-dong-123/moon-hlog/releases/tag/v0.2.0) · [基线 CI](https://github.com/guo-dong-123/moon-hlog/actions/runs/45922566764)

目标是把压测产物变成可重复判断、可定位的回归证据。CLI 供 CI 和开发者直接使用，分组、统计与判定逻辑也应能由其他 MoonBit 项目复用。

## 一、先让回归判定可靠

- 增加可选最低样本数，以每个标签和窗口为单位验证基准与候选。报告明确原因、两侧样本数和窗口坐标，区分 `pass`、`regression`、`insufficient_data`。输入格式错误仍走现有错误路径。启用严格门禁时，样本不足也应阻止流程通过，但原因与已确认退化分开呈现。
- 让 `compare` 和 `report` 复用同一判定逻辑。保留现有调用方式和 JSON 字段，新门禁通过显式选项启用。最低样本数是配置策略，统计置信度仍需结合多轮基准实验。
- 允许显式声明左右日志的计量单位。首版遇到声明冲突直接报告不可比。耗时单位来自采集端。HdrHistogram 的文本峰值列可以单独缩放，无法据此推断所有桶的单位。[Java 日志写入实现](https://github.com/HdrHistogram/HdrHistogram/blob/master/src/main/java/org/HdrHistogram/HistogramLogWriter.java)
- 验收用例包括正常基线、真实退化样例、缺失窗口、样本不足、零基线、单位冲突及旧命令兼容。用仓库现有 30 样本的 `write` 窗口证明启用最低样本门槛后确实报告证据不足，并用 Java 继续核对底层统计。

## 二、补一个真实生产者和一种接入方式

- 选一条真实日志链路。首选 jHiccup 生成的 `.hlog`，复现采集到 MoonHlog 报告的过程，记录采集版本、参数、计量单位和可比的运行环境。用同一文件核对 Java 读取结果。以后再按实际需求扩展日志生产者。[jHiccup](https://github.com/giltene/jHiccup)
- 给 GitHub Actions 提供一份可直接使用的工作流示例。用固定版本的基线文件，输出标签、回归窗口、P99 与样本数到 CI 摘要，同时保留 JSON 供自动化消费。三组案例分别验证通过、判定退化、证据不足。
- Mooncakes v0.3.0 已发布，独立模块通过 `moon add` 安装后的四后端测试及注册表 CLI 安装均已验证。若继续接入 Molt，优先评估可追踪的 `.hlog` 导出接缝。Molt 已负责 HTTP 施压、采集以及固定阈值判断，MoonHlog 可以在其产物上做两次运行的比较。[MoonBit 包发布文档](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html#publish-your-module) · [Molt 现有功能](https://github.com/paveg/molt#features)

## 三、优化窄窗口和大日志

当前 CLI 整文件读取并解码全部区间，然后按标签与窗口筛选和排序。在本机用同一有效 V2 负载生成一份 10 万行、约 9.3 MB 的合成日志，将它同时用作基准和候选运行 `report --window 1 --from 0 --until 1 --json`，仅输出一个窗口，单次测得峰值 RSS 约 182 MiB、耗时约 0.70 秒。这是便于复现的性能定位样例，尚需用不同桶密度、标签数和真实日志补测基线。

- 将行头解析与直方图解码分离。先按标签和起始时间选区间，再解码选中的负载。为旧全量解析 API 保留严格读取行为。对选择性读取明确记录哪些负载经过验证。
- 从按行读取、逐窗聚合做起。统计内存随选中窗口和桶的增长情况，测全量读取与窄窗口两种路径。验证乱序日志、多个标签、分块行尾、错误行号和毫秒边界。
- 优化验收用相同输入对照现有版本的 JSON 和 Java 统计，再记录耗时与峰值 RSS。加入大日志测试时固定数据生成参数和工具链。测量结果出来后再确定发布指标。

## 四、按使用反馈扩展

多文件分片合并需要统一对齐时间的基准，并确认输入分片互不重叠。收集到真实多 worker 日志后再定义兼容性和重复输入规则。静态 HTML 报告可基于稳定 JSON 做单文件导出。完整的 Web 平台、实时压测客户端、旧编码和浮点直方图支持需要下游场景来决定优先级。

第一批实现已覆盖最低样本数、JSON 判定原因和 CLI 回归测试。外部日志复现和 CI 接入示例已写入 [接入指南](INTEGRATION.md)。计量单位声明、严格流式读取与选择性负载解码也已实现。窄窗口的三次对照见 [性能基准](STREAMING_BENCHMARK.md)。公共注册表安装已验收，详见接入指南。
