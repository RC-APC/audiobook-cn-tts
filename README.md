# audiobook-cn-tts

**KOReader 听书插件（Audiobook Read-Along）· 云端中文 TTS 修改版**

---

## 📌 来源与归属（请先读这段）

本项目是 **[stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
的一个衍生修改版（derivative work）**，基于其 **0.2.8** 版本。

- **原作者 / 上游项目**：stradichenko — [github.com/stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
- **上游许可证**：GNU General Public License v3.0（GPL-3.0）
- **本仓库许可证**：GPL-3.0（与上游一致，详见 [`LICENSE`](./LICENSE)）
- **归属声明**：详见 [`NOTICE`](./NOTICE)

原作者及上游项目的全部功劳归其所有。本仓库仅在原版基础上增加**云端中文 TTS**
等适配能力，未对上游功能做删减。

> ⚠️ 按 GPLv3 要求：如果你分发本项目的修改版本，**必须**同样以 GPLv3 发布、
> 提供完整对应源码，并保留本归属声明。

---

## 这是什么

在原版「有声书跟读」能力之上，增加了一套**云端 TTS 后端**：把当前阅读页的文字送到
**你自己的语音合成中继**，取回中文语音朗读，并让高亮跟随进度逐句移动。

适合在 Kindle、微信读书 e-ink（MiuRead）等墨水屏设备上听中文书——这些设备本地
没有高质量中文语音引擎，而云端合成可以绕过这个限制。

### 相比原版新增了什么

| 能力 | 说明 |
|---|---|
| **云端 TTS 后端** | 通过 `cloud_tts_helper.sh` 把每句文本发到你自己的中继，取回 Edge-TTS 合成的中文语音。中继可自托管（见 [`relay/`](./relay)），也可对接任何兼容服务。 |
| **中文音色四选一** | 晓晓 / 云希 / 云扬 / 晓伊，在插件设置里一键切换，朗读时即时生效。 |
| **预取（prefetch）** | 朗读当前句时后台并行合成后 1~2 句，减少句间停顿。采用队列 + 空文件校验，云端抖动不会跳句。 |
| **中文分句 / 高亮对齐** | 补齐 CJK 标点分句与高亮字节偏移映射，中文整句不再整页高亮或吞字。 |
| **MiuRead（微信读书 e-ink）适配** | 叠加层自动暂停默认关闭（避免常驻浮层被误判为用户开了菜单而中途暂停）；双击页面即可启动朗读。 |
| **半填中继地址** | 出厂为占位地址，公网用户填自己的域名、局域网用户填 `http://` 内网地址即可，无需改代码。 |

---

## 安装（普通用户请从这里开始）

### ✅ 普通用户：下载完整安装包（推荐）

**本 git 仓库不含离线语音引擎**（espeak-ng / Piper / ffmpeg 等约 230MB 二进制），
因此**不要 clone 本仓库来安装**。

请前往本仓库的 **[GitHub Releases](https://github.com/RC-APC/audiobook-cn-tts/releases)**
下载完整可安装包：

```
audiobook-cn-tts-v0.2.8-cn-tts.zip
```

安装步骤：

1. 解压 `audiobook-cn-tts-v0.2.8-cn-tts.zip`，得到 `audiobook.koplugin/` 目录。
   - **注意**：目录里应直接是 `main.lua`、`cloud_tts.cfg`、`cloud_tts_helper.sh`
     等文件，**不要出现双层 `audiobook.koplugin/audiobook.koplugin/`**。
2. 复制到设备的 KOReader 插件目录（覆盖旧的同名目录）：
   - Kindle：`/mnt/us/koreader/plugins/`
   - 微信读书 e-ink（MiuRead）：对应 KOReader 插件目录
3. **彻底退出 KOReader 再重进**（杀掉进程重新打开，不是退回书架），否则旧缓存还在跑。
4. 按下方「配置」填写中继地址即可使用。

> 完整图文教程见 **[使用教程.md](https://github.com/RC-APC/audiobook-cn-tts/blob/main/使用教程.md)**。

### 🛠️ 开发者：clone 源码自行构建

```bash
git clone https://github.com/RC-APC/audiobook-cn-tts.git
cd audiobook-cn-tts
```

仓库内为 Lua 源码。**离线引擎需自行获取**（可从上游 Releases 下载对应引擎，
或参考上游的构建脚本）。仅使用云端 TTS 时不需要本地引擎。

---

## 配置

### 1. 填云端 TTS 中继地址

云端朗读依赖**你自己的 TTS 中继服务**（不在插件包内）。格式一定是：

```
协议://域名或IP:端口/tts
```

- 公网部署：`https://your-domain.com/tts`
- 局域网部署：`http://192.168.1.50:5000/tts`

**在哪里填**：☰ → Audiobook Read-Along → 设置 → **云端 TTS 中继地址**。

> ⚠️ **协议必须一致**：https 中继填 `https://`，局域网 http 中继填 `http://`。
> 混填会让中继返回 400，表现为「大段空白、跳段、或完全没声音」。

### 2. 自建中继（可选）

若你没有现成的中继服务，本仓库的 [`relay/`](./relay) 提供了参考实现：

- `relay/standalone/` —— 最小可运行版本（Flask + Edge-TTS，返回 WAV）
- `relay/cloud/` —— 部署到 Render 等云平台的版本
- `relay/README.md` —— 详细部署说明

中继需满足的接口约定（插件默认以 **GET** 请求）：

```
GET {你的中继地址}?voice=音色名&text=文字内容&rate=±百分比
```

并**返回 WAV 音频**（`Content-Type: audio/wav`）。

### 3. 选音色

☰ → Audiobook Read-Along → 设置 → **云端 TTS 音色**，四选一：

- 晓晓（zh-CN-XiaoxiaoNeural）
- 云希（zh-CN-YunxiNeural）← 默认
- 云扬（zh-CN-YunyangNeural）
- 晓伊（zh-CN-XiaoYiNeural）

### 4. 开始听书

- **菜单启动**：☰ → Audiobook Read-Along → Start Text-to-Speech from current page
- **双击页面**：在阅读页双击也可启动

---

## 常见问题

**Q：菜单「语音设置」后面显示的是中文音色，不是 `English (GB)`？**
这是正常的新版本行为。若仍显示 `English (GB)`，说明后端没切到云端，检查中继地址是否填对。

**Q：点了开始但没声音？**
① 确认中继地址填对且协议匹配；② 用电脑 `curl` 一下你的 `/tts` 验证是否返回音频；
③ 在设备 KOReader 目录的 `crash.log` 里找 `BUILD` 戳，确认新代码在运行。

**Q：朗读的是英文？**
说明还在用本地 espeak 引擎而没走云端。确认中继地址已正确填写、音色已选中文。

**Q：一打开阅读就疯狂翻页？**
通常是"合成失败 → 自动翻下一句"的连锁。根因一般是中继地址错误、https/http 混填，
或 helper 脚本缺失。优先核对中继地址。

---

## 仓库内容说明

本仓库为**纯源码仓库**（约 2.7MB / 45 个文件），**不含**离线语音引擎二进制。
完整可安装包通过 GitHub Releases 分发。详见 [`NOTICE`](./NOTICE)。

```
audiobook-cn-tts/
├── main.lua / menubuilder.lua / ttsengine.lua ...   # 插件 Lua 源码
├── cloud_tts.cfg                                     # 中继配置（音色/地址/超时）
├── cloud_tts_helper.sh                               # 云端 TTS 调用helper
├── audiobook_gettext.lua / l10n_zh_CN.lua            # 中文界面
├── relay/                                            # 自建中继参考实现
├── LICENSE                                           # GPLv3
└── NOTICE                                            # 归属声明（上游: stradichenko）
```

## 许可证

GPL-3.0。上游项目 [stradichenko/audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)
同为 GPL-3.0。归属与衍生关系见 [`NOTICE`](./NOTICE)。

```
audiobook-cn-tts is a derivative work of stradichenko/audiobook.koplugin (GPL-3.0).
All credits to the original author. This version adds a cloud Chinese TTS backend
and MiuRead/e-ink adaptations.
```
