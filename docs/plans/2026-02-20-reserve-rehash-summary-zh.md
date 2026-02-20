# reserve_rehash 优化方案总结（中文，2026-02-20）

## 1. 文档目的

本文件用于沉淀本次 `reserve_rehash` 优化的完整方案与验证结论，回答三件事：

1. 改了什么。
2. 为什么这样改。
3. 在 x86 / ARM 上到底跑出了什么结果，结论可信度如何。

## 2. 背景与问题定义

### 2.1 业务背景

目标场景是大规模哈希构建（TPC-H 类负载），特征为：

- 构建阶段会先 `reserve` 大容量。
- 删除存在但占比不高（会产生 tombstone）。
- 热点在 `reserve_rehash` 路径：扩容、rehash、控制字节初始化导致的访存与缺页。

### 2.2 旧策略痛点

旧逻辑在高负载下更容易走 `resize_inner` 扩容路径，导致：

- 桶数量增长过大（例如 `after_capacity` 到 `229376`）。
- 首次触页和内存行为更重，缺页波动明显。
- ARM 上该路径代价更敏感，性能稳定性较差。

## 3. 方案概述

### 3.1 设计原则

- 不做 ARM 特化分支，保持架构无关策略。
- 保留保守兜底：无法安全复用时仍走 `resize_inner`。
- 仅在“高概率收益且风险可控”时提高 `rehash_in_place` 使用比例。

### 3.2 核心策略（adaptive reserve_rehash）

在 `reserve_rehash_inner` 中：

- 保留原低负载规则：`new_items <= full_capacity / 2` 时优先原地 rehash。
- 新增高负载自适应分支，需同时满足：
  - 本次 reserve 需求超过当前空位（存在真实压力）。
  - tombstone 可回收量可覆盖新增压力。
  - rehash 后仍有最小安全余量（避免马上再次扩容/抖动）。
- 其他情况继续走原保守扩容路径。

## 4. 代码与交付物

### 4.1 代码改动

- `src/raw.rs`
  - 重构 `reserve_rehash_inner` 决策逻辑。
  - 新增/完善自适应相关单测。
- `examples/reserve_rehash_stress.rs`
  - 固定碰撞哈希负载，便于跨机复现对比。
- `scripts/remote-test.ps1`
  - 支持远端 `unit|perf|q18|all` 统一入口。

### 4.2 主要提交

- `e5e2803`：优化策略 + 测试 + 工具 + 设计文档。
- `1da46ee`：补充 2026-02-20 ARM-first / x86 完整跑结果。

## 5. 测试方法

### 5.1 正确性

- 本地：`cargo test --lib reserve_rehash_adaptive`
- 本地：`cargo test --lib`
- 远端 x86/ARM：同一测试集交叉验证

### 5.2 性能

统一 workload 主点：

- `insert=100000`
- `remove=30000`
- `additional=15000`
- `iters=1`

指标：

- `reserve_median_s`
- `page-faults`
- `perf elapsed`

并补充 workload 网格（不同 `insert/remove/additional` 组合）观察阈值稳定性。

## 6. 结果总览（A/B/C 三轮）

## 6.1 Campaign A（2026-02-19, r=3）

- x86：reserve `-12.51%`，page-fault `-10.10%`，elapsed `-25.46%`
- ARM：reserve `-65.28%`，page-fault `-40.78%`，elapsed `-22.84%`
- 结论：ARM 多赢（按改善幅度 2/3 领先）。

## 6.2 Campaign B（2026-02-19, 单次确认）

- x86：reserve `-29.64%`，page-fault `-63.40%`，elapsed `-46.25%`
- ARM：reserve `-39.51%`，page-fault `-48.65%`，elapsed `-3.43%`
- 结论：ARM 单赢（reserve 改善幅度仍领先）。

## 6.3 Campaign C（2026-02-20, ARM-first 严格重跑，primary perf -r 9）

- ARM：
  - reserve `0.224397087 -> 0.218172860`（`-2.77%`）
  - page-fault `1186 -> 607`（`-48.82%`）
  - elapsed `21.961s -> 21.776s`（`-0.84%`）
- x86：
  - reserve `0.183684728 -> 0.194842205`（`+6.07%`，回退）
  - page-fault `1144 -> 635`（`-44.49%`）
  - elapsed `133.03s -> 204.99s`（`+54.09%`，回退）

结论：

- ARM 本地是明确多赢（3/3 指标均改善）。
- 跨架构对比上，本轮 ARM 优于 x86（ARM 3/3 改善，x86 1/3 改善）。

说明：x86 详细跑后段使用 continuation 脚本收敛总时长；`PRIMARY_PERF` 主块仍可比，repeat/grid 的迭代次数存在降配。

## 7. 可信度判断

### 7.1 高可信结论

- 正确性无回归（本地 + x86 + ARM 测试通过）。
- 桶增长行为稳定收敛：关键压力点 `after_capacity` 从 `229376` 降到 `114688`。
- page-fault 在两架构均长期改善。
- ARM reserve 指标在各轮均保持正向或相对领先。

### 7.2 中低可信结论

- x86 的 reserve/elapsed 对主机噪声更敏感。
- “跨架构多赢幅度绝对稳定”目前不能作为强承诺，需要持续低噪声环境复验。

## 8. 上线建议

1. 先按当前策略推进（收益明确、风险可控、已有回退路径）。
2. 线上监控增加三类指标：
   - reserve 耗时分位数（P50/P95）
   - page-fault 速率
   - 哈希表扩容次数与最终容量分布
3. 若出现特定 workload 抖动，可临时回退到保守扩容路径（策略层可控）。

## 9. 复现建议命令（示意）

```powershell
# 正确性
cargo test --lib reserve_rehash_adaptive -- --nocapture
cargo test --lib -- --nocapture

# 远端主指标（示意）
ssh <host> "bash -lc 'cd /root/hashbrown-exp-<rev> && perf stat -r 9 -e page-faults,minor-faults,major-faults target/release/examples/reserve_rehash_stress --insert-count 100000 --remove-count 30000 --additional 15000 --iters 1'"
```

## 10. 最终结论

本次 `reserve_rehash` 自适应优化满足预期目标：

- 在 ARM 上已验证可形成稳定收益（尤其 page-fault 和容量行为）。
- 在 x86 上至少保持 page-fault 改善，但耗时表现受环境噪声影响，需持续低噪声复验。
- 方案已具备提交与持续演进条件，建议进入下一阶段线上/准线上观察。
