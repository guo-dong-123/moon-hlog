# MoonHlog 评委演示

## 直接运行

从 [GitHub Release v0.3.0](https://github.com/guo-dong-123/moon-hlog/releases/tag/v0.3.0) 下载适合当前系统的命令行压缩包并解压。两个样例随压缩包提供。在解压目录运行：

```sh
./hlog summary baseline.hlog --tag read --json
./hlog report baseline.hlog candidate.hlog --window 1 --max-p99-increase-pct 5 --json
./hlog report baseline.hlog candidate.hlog --window 1 --tag write --min-samples 100 --json
```

`summary` 退出 0，`report` 退出 1。合成样例的第二个 `read` 相对时间窗口 `[1, 2)` 秒内，P50 保持 10,007 ns，P99 从 10,007 ns 增至 180,095 ns。`write` 窗口的 P99 保持 75,007 ns。每个窗口先合并桶计数，再计算分位数。若一侧缺样本，报告单独标记，启用阈值时让 CI 失败。

第三条命令报告样本数不足，退出 1。单位声明、真实 jHiccup 数据接入和选择性读取见 [接入指南](INTEGRATION.md) 与 [性能基准](STREAMING_BENCHMARK.md)。

## 源码构建与独立核验

使用 MoonBit `0.10.11+6ff76a5f9`。在仓库根目录运行：

```sh
moon update
moon test --target all --deny-warn
moon build --target native --release --deny-warn
scripts/verify-interop.sh _build/native/release/build/cmd/hlog/hlog.exe
moon package
scripts/verify-consumer.sh _build/publish/guo-dong-123-moon-hlog-0.3.0.zip
```

Java 对照脚本重新生成确定性日志并核对 8 组全局或筛选摘要、3 行窗口报告的双侧统计、两次日志回写的时间戳、标签和逐桶计数，以及 CLI 的退出码 0、1、2。还验证了两种时间基准下同一个 0.300 秒的区间落入同一窗口。脚本首次运行会下载经过 SHA-256 校验的 Java 参考库，也可用 `HDRHISTOGRAM_JAR` 指向本地 JAR。

独立消费者脚本从 `moon package` 产物解压库，在新工作区导入公开 API，验证四个后端，再运行通过 `moon install` 安装的 CLI。
