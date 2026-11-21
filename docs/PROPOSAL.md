# MoonHlog 项目申报书

## 基本信息

- **项目名称** MoonHlog（HdrHistogram 日志工具库与命令行工具）
- **参赛者 GitHub 账号** `guo-dong-123`
- **GitHub 仓库链接** [github.com/guo-dong-123/moon-hlog](https://github.com/guo-dong-123/moon-hlog)
- **项目方向** MoonBit 工具库、性能测试与开发者工具
- **是否为移植项目** 否，使用 MoonBit 独立实现

## 项目简介

同一项性能测试往往会产生多个时间段或分片的延迟直方图。直接平均各段的 P99 会丢失分布信息，难以判断整次运行的延迟是否退化。MoonHlog 面向性能测试和 CI 维护者，用 MoonBit 读取 HdrHistogram `.hlog` 日志，合并所选区间的直方图计数，再计算整体分位数，从而比较基准版与候选版。

项目将日志编解码和统计做成可复用库，以 CLI 提供本地文件摘要和回归比较。CI 可根据比较结果决定是否阻止候选版本进入下一阶段。

## 核心功能范围

- 读写 `.hlog` 区间记录、标签和时间基准，支持 V2 压缩整数直方图。
- 按标签或相对时间窗口筛选区间，合并布局一致的直方图，汇总样本数和 P50、P95、P99、P99.9。
- 通过 `summary` 查看摘要，使用 `compare` 比较两次运行的 P99，超过设定增幅时让 CI 失败。`rewrite` 可重新编码日志。
- 使用 Java HdrHistogram 2.2.2 完成 8 次摘要对照和 2 次回写核验。CLI 验证通过时退出 0、超阈值时退出 1、输入错误时退出 2。
- 在合成的 `read` 样本中，两次运行的 P50 持平，P99 从 10,007 ns 升至 180,095 ns，超过 5% 回归阈值。

## 移植或参考说明

- MoonHlog 以 MIT 许可证发布。日志与直方图的交换格式参考 Java HdrHistogram，后者以 CC0 1.0 或 BSD-2-Clause 许可提供。[上游许可证](https://github.com/HdrHistogram/HdrHistogram/blob/master/LICENSE.txt)
- zlib 编解码复用 `moonbit-community/flate`，命令行文件访问和进程退出使用 `moonbitlang/x`。两项依赖均采用 Apache-2.0 许可证。
