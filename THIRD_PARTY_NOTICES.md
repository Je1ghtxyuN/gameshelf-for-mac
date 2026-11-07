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

The native-cache adapter recognizes the pinned Ren’Py 8.3.7.25031702 bootstrap, error-reporting and archive-loader templates. It modifies only newly prepared runtime copies to keep bytecode and generated reports outside sealed application resources. The upstream MIT license and Tom Rothamel copyright notices remain in the adapted files; the test fixtures retain the same notices. For mounted SMB resources, a scoped read-only RPA context can handle EBADF raised solely by close; read and parse failures and all save-file writes retain their normal error behavior. Unknown templates are left unchanged.

## Sparkle 2.10.1

GameShelf integrates the [Sparkle update framework](https://sparkle-project.org/)
and uses its official `generate_appcast` and `sign_update` publishing tools.
Upstream: https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1
The pinned distribution SHA-256 is
`1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`.
Sparkle's complete upstream license and bundled component notices follow;
they retain their own terms independently of GameShelf's MIT license.

```text
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
EXTERNAL LICENSES
=================

bspatch.c and bsdiff.c, from bsdiff 4.3 <http://www.daemonology.net/bsdiff/>:

Copyright 2003-2005 Colin Percival
All rights reserved

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

--

sais.c and sais.h, from sais-lite (2010/08/07) <https://sites.google.com/site/yuta256/sais>:

The sais-lite copyright is as follows:

Copyright (c) 2008-2010 Yuta Mori All Rights Reserved.

Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

--

Portable C implementation of Ed25519, from https://github.com/orlp/ed25519

Copyright (c) 2015 Orson Peters <orsonpeters@gmail.com>

This software is provided 'as-is', without any express or implied warranty. In no event will the
authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose, including commercial
applications, and to alter it and redistribute it freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim that you wrote the
   original software. If you use this software in a product, an acknowledgment in the product
   documentation would be appreciated but is not required.

2. Altered source versions must be plainly marked as such, and must not be misrepresented as
   being the original software.

3. This notice may not be removed or altered from any source distribution.

--

SUSignatureVerifier.m:

Copyright (c) 2011 Mark Hamlin.

All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted providing that the following conditions
are met:
1. Redistributions of source code must retain the above copyright
   notice, this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright
   notice, this list of conditions and the following disclaimer in the
   documentation and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

```
