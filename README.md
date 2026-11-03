# GameShelf for Mac

macOS 游戏兼容与管理客户端

GameShelf 是 macOS 上的游戏库管理与启动工具，支持本地磁盘和 NAS 上的游戏目录，可管理分类、封面、运行参数、存档迁移和游玩时长。项目仓库名为 `gameshelf-for-mac`。

## 运行与兼容性

已验证环境为 macOS 15 或更新版本的 Apple Silicon Mac；Intel Mac 尚未验证。构建脚本支持选择目标架构，但这不代表对应平台或所有游戏均已验证。

应用根据游戏类型使用不同运行方式：

- **原生应用**：启动已有的 macOS 游戏应用；兼容性取决于游戏本身支持的系统与架构。
- **Wine / Wineskin**：在设置中选择已有的 Wineskin `.app` 运行环境，用于适合该环境的 Windows 游戏。项目不附带 Wine 或 Wineskin，不保证任意 EXE 均可运行。
- **Web 游戏**：通过 WebKit 与本机资源服务运行受支持的 HTML 游戏；浏览器特性、游戏插件和存档实现可能影响兼容性。
- **Ren’Py 等引擎适配**：在满足受支持版本与运行环境条件时使用相应适配路径；不满足条件时可能需要 Wine 或无法运行。

引擎识别不等于可玩性验证。游戏版本、图形接口、插件、字体及第三方运行环境都会影响结果。

首次使用时导入自己拥有使用权的目录，在设置中选择运行环境和运行数据位置。游戏可保留在本地或 NAS；运行数据可按设置放在所选位置。网络卷需要保持挂载并具有相应读写权限。迁移存档前请退出游戏并备份进度。

## 构建与测试

需要 macOS 15+、Apple Command Line Tools（含 Swift、iconutil、codesign）、Python 3.10+、Ruby，以及支持 `node:test` 的 Node.js 20+。工具通过 PATH 查找，无需固定 Homebrew 安装目录。

```sh
./build.sh
./test.sh
```

构建产物为 `dist/GameShelf.app`，默认使用当前 Mac 的架构。可设置 `ARCH=arm64` 或 `ARCH=x86_64`；Intel 目标尚未验证。构建进行本地临时签名，不包含开发者证书或公证。

测试使用临时目录中的合成文件，不启动游戏、不访问真实游戏库，也不下载依赖。资源服务测试需要允许绑定本机回环端口。Ren’Py 离线迁移工具的使用方式见 `python3 Tools/migrate_renpy_saves.py --help`。

## 隐私

游戏库元数据保存在本机，运行数据保存到设置中选择的本地或网络卷位置。在线封面功能可能向 VNDB / Steam 发送游戏标题等检索内容；可在设置中关闭自动在线封面。详情见 [隐私说明](PRIVACY.md)。

## 许可证与第三方内容

本项目以 [MIT License](LICENSE) 提供，版权归 GameShelf contributors。`append_rgss3a.py` 的格式参考归属及上游 MIT 许可见 [第三方说明](THIRD_PARTY_NOTICES.md)。

仓库不包含商业游戏、游戏数据、封面图片、字体、Wine、Wineskin、Ren’Py SDK 或其他第三方引擎二进制文件。上述内容由使用者合法取得，并遵守各自的许可和服务条款；本项目的 MIT 许可不覆盖这些内容。产品名称用于说明互操作对象。
