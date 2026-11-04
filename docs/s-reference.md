# S家参照：本地文件怎么准备

S家是本项目对照的一款商用网球分析 App。它的模型、导出数据和研究记录都**不进 Git**，只放在各人自己的电脑上。这份公开文件只说明本地放什么、放在哪；没有这些本地文件也能开发、构建和测试。

## 放在哪

| 内容 | 位置 | 必需吗 |
| --- | --- | --- |
| 你的研究笔记（S家的版本、导出方法、对它行为的观察） | `docs/s-reference.local.md` | 否 |
| S家 App 导出的逐拍参照行（JSON） | `.local/` 下任意位置 | 打分时需要 |
| S家模型（21 个编译模型 + `manifest.json`） | `.local/s-models/` | 只有 `COURT_MODEL_SET=both` / `sjia` 构建和 `court-analyze` 的 S家链需要 |
| S家链的代码（运行 S家模型的那部分，`CourtCore/` 和 `Tests/` 两个子目录） | `.local/s-chain/` | 同上 |

`*.local.md`、`.local/` 和 `assets/analysis-models/` 都被 `.gitignore` 忽略。提交前用 `git status` 确认它们没有出现。

## S家链的代码怎么接入

公开代码里只有一个接口 `ReferenceChain`（`Sources/CourtCore/ReferenceChain.swift`）。S家链的实现放在 `.local/s-chain/`，需要时由脚本链接进源码树：

```sh
scripts/reference-chain.sh on       # 链接到 Sources/CourtCore/Reference 和 Tests/CourtAppTests/Reference
scripts/reference-chain.sh off      # 去掉链接
scripts/reference-chain.sh status
```

- `COURT_MODEL_SET=both` / `sjia` 的 `build-mac.sh`、`generate-ios.sh` 会自动 `on`，默认构建（上架版）会自动 `off`；`build-mac.sh` 打包默认版时还会检查二进制里没有 S家链，有就停止。
- 链接后，`swift test` 会多跑 S家链自己的测试（`ReferenceEngineTests`），带模型的机位分析、离线补算测试也会跑起来；没链接时这些测试跳过。
- 在 git worktree 里，脚本找不到本 worktree 的 `.local/s-chain/` 时用主仓库的那一份；链接是符号链接，改动直接落在那一份上。
- 没有 S家链时，`court-analyze` 不带子命令、App 的 S家选项、离线补算都会明确报「这个构建不含 S家参照链」，不会退回别的方法。

## 没有 S家模型时怎么拿参照

1. 在自己的 Mac 上装 S家 App，用它分析同一段视频，导出逐拍结果。
2. 把导出的行转成 `compare_rows.py` 能读的 JSON（它能读 App 的逐拍 JSON，也能读带 `teacher` 列表的老师行，见脚本开头的说明）。
3. 自研这边跑 `court-analyze independent-live VIDEO MODEL_DIR auto OUT.json`，再打分：

```sh
python3 .claude/skills/inhouse-model-research/scripts/compare_rows.py REF.json OUT.json
python3 .claude/skills/inhouse-model-research/scripts/serve_score.py REF.json OUT.json
```

## 本地笔记建议记的内容

在 `docs/s-reference.local.md` 里记下：

- 用的是哪一天、哪台机器上的 S家 App，版本号是多少（不同版本的结果不要混在一起比）；
- 每段参照视频导出了哪些行、用什么方法导出和转换；
- 对 S家行为的观察，例如它把击球时刻定在哪里、球速取的是哪一段、哪些行明显是错的（例如击球时刻标晚）。

## 公开时的规则

- 公开的代码、文档和提交信息里只写「S家」，不写它的产品名、版本号、内部模型名或研究方法。
- 只提交对照后的汇总分数（检出率、一致率、球速误差），不提交参照行本身。
- 和 S家接近只说明两个软件结论相近，不说明谁更准。精度结论要靠独立参考（第二机位、物理自检等，不用雷达）。
