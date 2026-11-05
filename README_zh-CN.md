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

GameShelf 是一款原生 macOS 游戏兼容与管理客户端。扫描 Mac、外置盘或已挂载 NAS 中的目录，选择要添加的游戏；也可登录带账号管理的共享游戏库。

## 下载

**[下载最新版本](https://github.com/Je1ghtxyuN/gameshelf-for-mac/releases/latest)** · macOS 15+ · Apple Silicon

打开发布页中的 DMG，将 **GameShelf.app** 拖到 **Applications（应用程序）** 快捷方式上。

## 功能

- **统一游戏库**：通过封面和自定义分类，整理 Windows、原生 Mac、视觉小说和 2D 游戏。
- **扫描后选择添加**：设置游戏库目录，按完整游戏发现候选项；自行选择版本，语言启动器归在一起，设置工具不作为游戏卡片。
- **可选的账号共享库**：登录自建服务，浏览获准访问的游戏。资源留在服务器，每个账号使用独立可写空间，Wine 运行环境保存在本机。
- **原位置导入**：游戏可保留在本地磁盘、外置盘或已挂载的 NAS，也可以下载一份本地副本供离线游玩。
- **视觉小说导入**：识别 QLIE、CatSystem2、吉里吉里和 NScripter 特征，过滤设置工具，并优先显示汉化启动入口。
- **绑定启动入口**：存在多个可执行文件时，可选择平时使用的汉化启动器，之后直接启动。
- **多种运行方式**：Windows 游戏使用 Wine/Wineskin，Mac 游戏直接运行，并提供 Ren’Py 引擎适配与 HTML 游戏的 WebKit 内嵌运行。
- **游玩时长**：封面下显示累计时长，在 **属性 → 游玩记录** 中查看最近会话。
- **个性化整理**：支持改名、收藏、分类、本地封面和在线封面搜索。
- **存档管理**：提供按引擎适配的存档迁移、备份，以及重新连接游戏目录后的稳定条目标识。

## 开始使用

首次启动可选择 **本地使用**、**连接共享库** 或 **创建共享库**。本地使用无需账号。新部署的共享服务会生成私有的一次性管理员初始化文件，在创建流程中打开该文件，即可自行设置管理员账号和密码。

1. 点击 **添加游戏库**，添加包含游戏的目录；本地、外置盘和已挂载的网络目录采用相同流程。
2. 扫描后勾选要添加的游戏，必要时选择汉化启动入口。不会自动批量加入游戏库；特殊情况仍可使用 **文件 → 手动添加游戏**。
3. Windows 游戏先在 **设置** 中选择已有的 **Wineskin `.app`** 运行环境；原生 Mac 游戏使用自身的应用，Ren’Py 引擎适配使用对应版本的运行库。
4. 点击游戏卡片上的 **启动**。通过 **⋯ → 属性** 修改显示名称、启动设置、文件位置、封面和分类。

NAS 游戏会保留在原目录。游玩时保持共享目录挂载，断开后重新连接同一共享目录即可继续使用已有条目；**下载到本地** 可创建离线副本。

账号共享模式下，打开 **共享库**，使用服务器邀请文件（或填写地址）连接并登录，再勾选获准访问的游戏；无需提供 NAS 账号。服务端通过加密 SMB3 提供网络资源，为每个账号、每款游戏建立独立可写空间。共享游戏按网络方式运行；下载副本功能仅用于直接导入的游戏。

管理员可在客户端点击 **添加游戏** 或 **服务器管理**，扫描目录、检查存档排除路径、发布所选游戏，并创建账号及管理授权。原生管理面板沿用已保存的安全连接，无需先登录浏览器。

账号、扫描发布、游戏授权、证书与原存档排除设置见[服务端部署说明](Server/README.md)。共享 Windows 游戏使用独立 Wine 用户目录，已管理的原生 Ren’Py 使用独立存档目录；经过验证的 RPG Maker MZ 网页适配将存档与设置写入账号专属网络空间，退出前确认写入。其他共享网页及原生引擎需要各自的存档适配。

共享库登录仅在本次客户端运行期间有效。密码和登录令牌不写入磁盘，客户端不访问 macOS 钥匙串；重启后保留服务器地址和账号名称。

连接共享库后，可在「账号」页面绑定本机游戏库资料。游戏名称、分类、收藏、时长和封面缩略图同步到个人账号，游戏文件与存档保持原位。共享库默认封面属于已发布的游戏，个人换图仅影响自己。

时长在 GameShelf 运行期间记录，包含游戏切到后台的时间，电脑睡眠时暂停；从启用此功能后开始累计。

已确认的名称别名和封面会保存在本机，后续添加同一游戏时复用。发布匹配的游戏时会附带默认名称与封面，供获授权玩家使用；个人更换的封面单独保留。

## 从源码构建

安装 Apple Command Line Tools、Python 3.12+、Ruby 和 Node.js 20+，然后执行：

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
