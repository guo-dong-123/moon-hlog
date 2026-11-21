# MoonHlog 评委演示

使用 MoonBit `0.10.11+6ff76a5f9`。在仓库根目录构建 CLI 后，演示使用仓库内合成日志。依赖完成下载后，演示命令可离线运行。

```sh
moon update
moon build --target native --release
hlog=_build/native/release/build/cmd/hlog/hlog.exe

"$hlog" summary tests/fixtures/baseline.hlog --tag read --json
"$hlog" summary tests/fixtures/candidate.hlog --tag read --json
"$hlog" compare tests/fixtures/baseline.hlog tests/fixtures/candidate.hlog \
  --tag read --max-p99-increase-pct 5
```

| 合成数据 | 样本数 | P50 | P99 |
| --- | ---: | ---: | ---: |
| 基准版 | 1,100 | 10,007 ns | 10,007 ns |
| 候选版 | 1,100 | 10,007 ns | 180,095 ns |

最后一条命令超过 5% 阈值，退出码为 1。用 `--from 1 --until 2` 可把统计限定到从第 1 秒到第 2 秒之间开始的区间。样本保留完整桶计数，CLI 在合并之后才计算分位数。

```sh
moon test --target all --deny-warn
scripts/verify-interop.sh _build/native/release/build/cmd/hlog/hlog.exe
```

对照脚本使用 Java HdrHistogram 2.2.2 重新生成合成日志，并独立计算预期值。它校验 8 组摘要、两次日志回写的时间戳/标签/逐桶计数，以及 CLI 的退出码 0、1、2。脚本首次运行获取带 SHA-256 校验的 Java 参考库。已有参考 JAR 时可通过 `HDRHISTOGRAM_JAR` 提供本地路径。
