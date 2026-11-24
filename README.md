# video-evidence-pdf

把录屏（尤其是聊天记录取证录屏）自动转成可直接打印/提交的证据 PDF：**在「画面停留」的位置截帧，按 A4 竖版每页 4 张（2×2）排版**。

全程本地处理，零第三方依赖，不需要 ffmpeg、Homebrew、pip 或 Xcode 工程——只用 macOS 自带的 AVFoundation / CoreGraphics / ImageIO / PDFKit，靠 Xcode 命令行工具里的 `xcrun swift` 直接跑脚本。

## 解决什么问题

取证录屏时，人会在需要留证的界面停顿，在不需要的地方快速划过。本工具按「画面是否静止」自动找出这些停顿点截帧，输出无损 PNG，再拼成纯图 PDF。截图按时间顺序排列，天然保持聊天记录的上下文连贯。

## 特性

- **零依赖**：一条命令都不用装，macOS + Xcode 命令行工具即可
- **本地优先**：不联网、不上传，聊天内容不离开本机
- **灵敏检测**：默认约 0.3 秒的停顿即可识别，不用刻意长时间停留
- **无损输出**：PNG 无损截图；PDF 内图像用 FlateDecode，文字不会被 JPEG 糊掉
- **自动去重**：相邻几乎相同的画面只保留一张
- **可调模式**：`--steady` 切到长停顿模式，减少出图数量
- **自检**：`--self-test` 用合成录屏跑完整链路，验证方向、分页、粘连

## 安装

作为 WorkBuddy Skill 使用，克隆到用户级 skills 目录：

```sh
git clone git@github.com:wyc960120/video-evidence-pdf.git ~/.workbuddy/skills/video-evidence-pdf
```

之后在 WorkBuddy 对话里说「把录屏转成证据 PDF」即可触发；或直接用命令行：

```sh
bash ~/.workbuddy/skills/video-evidence-pdf/run.sh "/path/to/录屏.mp4"
```

## 用法

```sh
SKILL=~/.workbuddy/skills/video-evidence-pdf

# 默认（灵敏模式，日常推荐）
bash "$SKILL/run.sh" "录屏.mp4"

# 稳妥模式：只在明显长停顿处截图，适合录得很慢的视频
bash "$SKILL/run.sh" "录屏.mp4" --steady

# 指定输出目录
bash "$SKILL/run.sh" "录屏.mp4" --outdir "/path/to/output"

# 阈值诊断（只打印逐帧帧差表，不产出文件）
bash "$SKILL/run.sh" "录屏.mp4" --diagnose

# 端到端自检
bash "$SKILL/run.sh" --self-test
```

## 输出

默认在视频同级 `<视频名>_evidence/` 下生成：

| 文件 | 说明 |
|---|---|
| `frames/NNN_HH-MM-SS.png` | 无损中间截图，文件名带序号和时间戳 |
| `<视频名>_evidence.pdf` | 最终产物：A4 竖版 2×2，每页 4 张，纯图无标注 |
| `capture_log.json` | 内部校验日志（每张图对应的视频时间戳） |

截图数不是 4 的倍数时，末页放剩余几张。

## 参数

完整说明见 [SKILL.md](SKILL.md)。常用：

| 参数 | 默认 | 说明 |
|---|---|---|
| `--step` | 0.1 | 抽帧步长（秒），决定能识别多短的停顿 |
| `--hold` | 0.2 | 最小停留时长（秒） |
| `--change` | 0.08 | 变化像素占比阈值，判断画面是否在动 |
| `--dedup` | 0.02 | 相邻截图差异低于此值视为同一屏 |
| `--steady` | | 稳妥模式：等价于 `step 0.5 / hold 0.8 / dedup 0` |
| `--no-log` | | 不写 `capture_log.json` |
| `--preview` | | 额外导出 PDF 首页预览 PNG |

## 隐私与安全

- 图像处理全部在本机脚本内完成，不联网、不上传任何服务。
- 工具本身不读取截图内容，只处理文件路径、参数和数值化的帧差结果。
- 生成物只写在你指定的本地目录，不会自动分享。

## 要求

- macOS（已在 macOS 26 / Apple Silicon 上验证）
- Xcode 命令行工具：`xcrun swift` 可用即可（`xcode-select --install`）

## License

未指定，按需使用。
