# 第三方说明

本项目的许可见 [LICENSE](LICENSE)。以下归属说明及上游许可与项目许可一并保留。

## rpg-extract 格式参考

`Tools/append_rgss3a.py` 参考了 [xi/rpg-extract](https://github.com/xi/rpg-extract) 中的 RGSS3A 格式实现，包括索引 XOR 和每四字节载荷密钥递推。为保守保留参考来源的归属与许可，本仓库附带上游完整 MIT 许可及版权声明，见 [LICENSE-rpg-extract.txt](LICENSE-rpg-extract.txt)。

本次通过公开 GitHub API 核对并固定的上游版本为 `d33337a51b89bf59d6eca91ea8f39203a635dab6`：

- [格式参考实现 rpg_extract.py](https://github.com/xi/rpg-extract/blob/d33337a51b89bf59d6eca91ea8f39203a635dab6/rpg_extract.py)
- [对应版本 LICENSE](https://github.com/xi/rpg-extract/blob/d33337a51b89bf59d6eca91ea8f39203a635dab6/LICENSE)
- [提交记录](https://github.com/xi/rpg-extract/commit/d33337a51b89bf59d6eca91ea8f39203a635dab6)

该提交是本次核对的固定参考版本，不声称还原最初开发时使用的版本。保留来源说明不代表对其余代码作整体原创性声明，也不表示上游作者认可本项目。

## 外部运行环境与资产

Wine、Wineskin、Ren’Py、RPG Maker、Unity、Steam、VNDB 等名称用于说明互操作对象。相关商标、第三方软件与服务保留各自权利。

仓库不分发游戏二进制、游戏数据、第三方引擎或 SDK、运行包、封面图片与字体。这些内容不受本项目 MIT 许可授权；使用者应自行合法取得，并遵守相应许可或服务条款。本仓库中的程序化图标源码不包含上述第三方图像资产。

## Wine window helper build support

`Tools/wine_window_launcher.c` is built with Zig and MinGW-w64 runtime support. The tested toolchain is Zig 0.17.1. Its accompanying Zig and MinGW-w64 notices are retained in [LICENSE-WineWindow-toolchain.txt](LICENSE-WineWindow-toolchain.txt) and included in the app bundle.

## Managed Wine downloads

GameShelf downloads the pinned upstream [Gcenx macOS Wine Staging 11.21](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.21) archive on demand; it is not embedded in the client package. The artifact URL, size and SHA-256 are recorded in `Resources/ManagedWine.json`. The complete upstream app and its notices are retained under the installed engine’s `Contents/Upstream` directory.

Wine is licensed under [LGPL-2.1-or-later](https://github.com/wine-mirror/wine/blob/master/LICENSE). Source and build information are available from the [upstream macOS builds repository](https://github.com/Gcenx/macOS_Wine_builds) and [Wine Staging](https://gitlab.winehq.org/wine/wine-staging). Included components retain their respective licenses. Rosetta is an Apple system component installed separately through macOS after user agreement.

## Native Ren’Py bootstrap adaptation

The native-cache adapter recognizes the pinned Ren’Py 8.3.7.25031702 bootstrap and error-reporting templates. It modifies only newly prepared runtime copies to keep bytecode and generated reports outside sealed application resources. The upstream MIT license and Tom Rothamel copyright notices remain in the adapted files; the test fixtures retain the same notices. Unknown templates are left unchanged.
