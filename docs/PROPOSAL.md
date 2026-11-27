# MoonHlog 项目申报书

## 基本信息

- **项目名称** MoonHlog（HdrHistogram 日志库与性能回归工具）
- **参赛者 GitHub 账号** guo-dong-123
- **GitHub 仓库链接** [https://github.com/guo-dong-123/moon-hlog](https://github.com/guo-dong-123/moon-hlog)
- **项目方向** MoonBit 工具库与性能测试
- **是否为移植项目** 否，使用 MoonBit 独立实现

## 项目简介

系统压测通常按时间段或请求标签记录延迟。MoonHlog 读取 HdrHistogram 日志，合并直方图桶计数后计算分位数，定位 P99 退化的标签和时间窗口。工具可接入 CI，依据样本数量、单位声明和 P99 增幅给出可追溯的回归判断。

## 核心功能范围

- 支持 V2 压缩整数直方图的读写、分位数汇总与按标签和相对时间窗口比较。
- v0.3.0 增加最低样本数门禁、计量单位声明、流式解析与选择性解码。JSON 保留判定原因和负载验证计数。
- 实际采集 jHiccup 2.0.10 日志，与 Java HdrHistogram 2.2.2 核对摘要、区间和逐桶回写结果。CI 示例区分通过、退化和证据不足。
- 本机 10 万行合成日志窄窗口查询，三次测量的峰值 RSS 中位数由 v0.2.0 的 182.33 MiB 降为严格流式模式的 2.89 MiB，共享统计字段一致。选择性模式用时 0.28 秒，原版为 0.68 秒。
- 四个后端各通过 15 项库测试和 2 项独立接入测试。详见 [评委演示](https://github.com/guo-dong-123/moon-hlog/blob/main/docs/REVIEWER_DEMO.md)。

## 移植或参考说明

- 项目采用 MIT 许可证。日志格式参考 Java HdrHistogram，其许可证为 CC0 1.0 / BSD-2-Clause。
- zlib 编解码复用 moonbit-community/flate，Native 输入输出使用 moonbitlang/x 和 moonbitlang/async，均为 Apache-2.0 许可证。
