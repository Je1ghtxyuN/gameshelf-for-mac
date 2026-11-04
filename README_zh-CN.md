<p align="center">
  <img src="https://count.getloli.com/@gameshelf-for-mac?theme=moebooru&amp;padding=7&amp;darkmode=auto" alt="GameShelf visitors" width="460" />
</p>

<h1 align="center">GameShelf for Mac</h1>

<p align="center">在 macOS 上，统一管理与启动 Windows 和 Mac 游戏。</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
  <a href="https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest"><img src="https://img.shields.io/github/v/release/Je1ghtxyuN/gameshelf-for-mac?style=flat-square" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-black?style=flat-square&amp;logo=apple" alt="macOS 15+" />
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-7C3AED?style=flat-square" alt="Apple Silicon" />
  <img src="https://img.shields.io/badge/Swift-F05138?style=flat-square&amp;logo=swift&amp;logoColor=white" alt="Swift" />
</p>

<p align="center"><a href="README.md">English</a> · <strong>简体中文</strong></p>

GameShelf 是一款原生 macOS 游戏兼容与管理客户端。导入 Mac、本地外置盘或 NAS 中的游戏文件夹，即可在同一个游戏库中整理和启动游戏。

## 下载

**[下载最新版本](https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest)** · macOS 15+ · Apple Silicon

打开 `GameShelf-v1.0.1-macOS-arm64.dmg`，将 **GameShelf.app** 拖到 **Applications（应用程序）** 快捷方式上。也提供 ZIP 压缩包下载。

## 功能

- **统一游戏库**：通过封面和自定义分类，整理 Windows、原生 Mac、视觉小说和 2D 游戏。
- **原位置导入**：游戏可保留在本地磁盘、外置盘或已挂载的 NAS，也可以下载一份本地副本供离线游玩。
- **视觉小说导入**：识别 QLIE、CatSystem2、吉里吉里和 NScripter 特征，过滤设置工具，并优先显示汉化启动入口。
- **绑定启动入口**：存在多个可执行文件时，可选择平时使用的汉化启动器，之后直接启动。
- **多种运行方式**：Windows 游戏使用 Wine/Wineskin，Mac 游戏直接运行，并提供 Ren’Py 引擎适配与 HTML 游戏的 WebKit 内嵌运行。
- **游玩时长**：封面下显示累计时长，在 **属性 → 游玩记录** 中查看最近会话。
- **个性化整理**：支持改名、收藏、分类、本地封面和在线封面搜索。
- **存档管理**：提供按引擎适配的存档迁移、备份，以及重新连接游戏目录后的稳定条目标识。

## 开始使用

1. 点击 **导入游戏**，选择游戏根目录文件夹。
2. 找到多个启动入口时，选择你平时使用的版本，例如汉化启动器。
3. Windows 游戏先在 **设置** 中选择已有的 **Wineskin `.app`** 运行环境；原生 Mac 游戏使用自身的应用，Ren’Py 引擎适配使用对应版本的运行库。
4. 点击游戏卡片上的 **启动**。通过 **⋯ → 属性** 修改显示名称、启动设置、文件位置、封面和分类。

NAS 游戏会保留在原目录。游玩时保持共享目录挂载，断开后重新连接同一共享目录即可继续使用已有条目；**下载到本地** 可创建离线副本。

时长在 GameShelf 运行期间记录，包含游戏切到后台的时间，电脑睡眠时暂停；从启用此功能后开始累计。

## 从源码构建

安装 Apple Command Line Tools、Python 3.10+、Ruby 和 Node.js 20+，然后执行：

```sh
./build.sh
./test.sh
./package-dmg.sh
```

构建产物为 `dist/GameShelf.app`，使用本地临时签名。可通过 `ARCH=arm64 ./build.sh` 指定 Apple Silicon；开发构建也提供 `ARCH=x86_64` 选项。测试使用自动生成的样本和临时目录。

独立的 Ren’Py 存档迁移工具：

```sh
python3 Tools/migrate_renpy_saves.py --help
```

项目维护者：[Je1ghtxyuN](https://github.com/Je1ghtxyuN)。

## 许可与致谢

[MIT 许可证](LICENSE) · [第三方说明](THIRD_PARTY_NOTICES.md) · [隐私说明](PRIVACY.md)

访问计数器来自 [Moe Counter](https://github.com/journey-ad/Moe-Counter)，徽章由 [Shields.io](https://shields.io) 提供。
