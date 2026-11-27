# 外部日志与 GitHub Actions 接入

以下例子使用 v0.3.0。可使用发布包中的 CLI，也可从源码构建。

```sh
moon build --target native --release --deny-warn
hlog=./_build/native/release/build/cmd/hlog/hlog.exe
```

## 从 jHiccup 采集到 Java 对照

安装 JDK、`curl` 和 `unzip`。脚本使用经 SHA-256 核对的 Azul jHiccup 2.0.10 归档。它独立采集本机 JVM 平台调度延迟，直方图单位为纳秒。采样间隔使用 jHiccup 默认配置，每约一秒写入一个聚合区间。

```sh
scripts/capture-jhiccup.sh /tmp/my-run.hlog
"$hlog" summary /tmp/my-run.hlog --json
scripts/verify-interop.sh "$hlog" /tmp/my-run.hlog
```

最后一步同时对照样本数、P50、P95、P99、P99.9，以及 Java 读取 MoonHlog 回写结果后的区间时间、标签和每个桶的计数。Java 聚合从输入第一个区间复制直方图，以沿用采集端的精度和最小可分辨值。

仓库中的 `tests/fixtures/jhiccup-2.0.10.hlog` 来自 2026-11-27 本机采集，平台为 macOS ARM64、Java 17.0.6。该文件有 4 个区间、3,109 个样本，P99 为 2,818,047 ns。这个值用于重放和互操作验证。每次重新采集的值会随运行环境变化。默认 CI 用已记录文件核验。 [jHiccup 上游说明](https://github.com/giltene/jHiccup#readme)

## 接入 GitHub Actions

在包含当前源码的 MoonHlog 仓库或 fork 中，将 [示例工作流](../examples/github-actions/latency-gate.yml) 放入 `.github/workflows/`。工作流进入默认分支后，从 Actions 手动运行，可选择任一场景。

| 场景 | 比较对象 | JSON 结果 | 命令退出码 |
| --- | --- | --- | ---: |
| pass | 基准与自身的 `read` 窗口 | `pass` | 0 |
| regression | 基准和候选的 `read` 窗口 | `regression` | 1 |
| insufficient_data | 每侧 30 个样本的 `write` 窗口，最低要求 100 | `insufficient_data` | 1 |

两个失败场景会使门禁步骤失败，符合启用严格门禁时的预期。工作流仍上传完整 JSON，GitHub 工作摘要会显示标签、窗口、两侧样本数、P99 和判定原因。[GitHub Actions 工作摘要](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-commands#adding-a-job-summary)

在其他仓库中，把 [`run-gate.py`](../examples/github-actions/run-gate.py) 放入 CI 工作目录，前置步骤准备带最低样本门禁的 MoonHlog CLI，以及同单位、同采集配置的基准日志和候选日志。基准可固定到某次已验收运行的产物。门禁步骤用下面的方式替换示例中的合成文件。每次运行使用新的报告输出路径。

```sh
python3 run-gate.py ./hlog /tmp/moonhlog-report.json \
  baseline.hlog candidate.hlog --window 1 --min-samples 100 --max-p99-increase-pct 5 --baseline-unit ns --candidate-unit ns
```

## 从包归档验证接入

```sh
moon package
scripts/verify-consumer.sh _build/publish/guo-dong-123-moon-hlog-0.3.0.zip
```

消费测试解压构建包、通过独立模块导入公开 API，并安装和运行 CLI。公共注册表发布后，在空项目用 `moon add guo-dong-123/moon-hlog@<发布版本>` 安装，再跑同样的公开 API 测试。[MoonBit 包管理文档](https://docs.moonbitlang.com/en/latest/toolchain/moon/package-manage-tour.html)
