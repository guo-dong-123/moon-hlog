# MoonHlog 项目申报书

## 基本信息

- **项目名称** MoonHlog（HdrHistogram 日志库与性能回归工具）
- **参赛者 GitHub 账号** `guo-dong-123`
- **GitHub 仓库链接** [https://github.com/guo-dong-123/moon-hlog](https://github.com/guo-dong-123/moon-hlog)
- **项目方向** MoonBit 工具库与性能测试
- **是否为移植项目** 否，使用 MoonBit 独立实现

## 项目简介

系统压测通常按时间段或请求标签记录延迟。整体 P99 升高时，维护者需要知道慢在哪一段、哪一类请求，以及对照数据是否完整。MoonHlog 用 MoonBit 读取 HdrHistogram 日志，合并各窗口的桶计数后再算分位数。持续集成可按阈值拦截 P99 退化，并显式报告缺少样本的窗口。

## 核心功能范围

- `summary` 汇总 P50、P95、P99、P99.9，`compare` 比较两次运行，`rewrite` 回写 V2 压缩整数日志。
- v0.2.0 新增 `report` 和公开分组 API。可同时对照各标签和相对时间窗口，输出 JSON 并用退出码指示阈值失败。
- 合成示例的 `read` 窗口 [1, 2) 秒内，P50 保持 10,007 ns，P99 从 10,007 ns 增至 180,095 ns。相同的 0.300 秒记录在两种时间基准下归入同一窗口。
- 四个后端各通过 13 项库测试，独立消费者各验证 2 个公开 API 场景。Java HdrHistogram 2.2.2 用于对照摘要、窗口统计和逐桶回写结果。
- 复现与安装说明见 [评委演示](https://github.com/guo-dong-123/moon-hlog/blob/main/docs/REVIEWER_DEMO.md)。

## 移植或参考说明

- 项目使用 MIT 许可证。交换格式参考 Java HdrHistogram，后者以 CC0 1.0 或 BSD-2-Clause 许可提供。
- zlib 编解码依赖 `moonbit-community/flate`，CLI 文件和进程操作依赖 `moonbitlang/x`，两者采用 Apache-2.0 许可证。
