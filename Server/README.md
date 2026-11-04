# GameShelf standalone Linux gateway / 独立 Linux 共享库网关

Python **3.12 standard library**, SQLite, Linux OverlayFS and a **separate container Samba**. No host Samba configuration, host users, NAS credentials, original games or existing saves are modified. No game is published automatically. Source editions must remain frozen while published.

本组件使用 Python 3.12 标准库、SQLite、OverlayFS 和独立容器 Samba。源目录只读，账号进度仅写入专用 ext4 状态目录；不修改宿主 Samba、宿主账号、原游戏或已有存档。扫描后必须勾选发布并授权。

## Deployment / 部署

Use a dedicated Linux Docker container. Upper/work must be on **ext4**, not Docker overlay2, NFS, SMB, macOS bind mounts or an existing save directory. The driver refuses other upper filesystems and writable sources. State and source paths must not overlap, including nested paths or bind aliases referring to overlapping physical filesystem roots. Linux mountinfo is checked before state initialization. Start with an empty, private state directory **beside**, not inside, immutable game roots. Do not repurpose a pre-existing state tree. For multiple roots, add separate read-only bind mounts and list their container paths in `GAMESHELF_SOURCE_ROOTS` (JSON array).

必须使用 Linux Docker，upper/work 为独立 ext4 目录。状态目录与源目录互不包含，首次使用全新私有目录，不挪用已有存档。多个源需分别只读挂载，并修改 `GAMESHELF_SOURCE_ROOTS` JSON 数组。宿主须保证源挂载下的子挂载也只读；发布期间不要修改或替换源版本。

Copy `.env.example` to a private `.env` beside `compose.yaml`; set the paths. Compose refuses to create missing bind paths. Set a client-reachable DNS hostname, dedicated HTTPS **8787** and SMB **1445** ports. Existing host SMB **445** stays untouched. The default host bind IP is loopback: set `GAMESHELF_BIND_IP` to the intended LAN interface address to allow LAN clients. Restrict both ports to intended clients using the host firewall. No remote deployment is performed by this repository's tests.

复制 `.env.example` 为私有 `.env` 并填写路径。默认仅绑定宿主回环地址；局域网访问需将 `GAMESHELF_BIND_IP` 改为指定网卡地址。HTTPS 8787、SMB 1445 与宿主现有 445 分离。配置文件和密码文件不要提交到仓库。

The service has no `--privileged`, host network/PID namespace, Docker socket, host devices or host Samba mounts. `SYS_ADMIN` permits private OverlayFS mounts; CHOWN/DAC_OVERRIDE/FOWNER prepare metadata; SETUID/SETGID let Samba use unprivileged account identities; MKNOD permits overlay whiteouts; NET_BIND_SERVICE binds container port 445. Session Unix uids are distinct; shares use a stable **unprivileged account** `force user`, never root. The container filesystem is ephemeral and writable because `useradd` needs its own `/etc`; only `/state` persists. The default Docker seccomp profile is retained. Docker's stock AppArmor policy blocks mounts, so Compose selects `apparmor:unconfined`; replace it with a reviewed mount-capable local profile if available. This is a mount-capable service, not a hostile-code execution container: it never executes uploaded games.

容器仅增加挂载、文件权限准备、Samba 身份切换及白化文件所需能力；不使用特权模式或宿主网络/PID/设备。Samba 的文件访问身份是账号私有普通 uid，不是 root。默认保留 Docker seccomp；默认 AppArmor 禁止挂载，因此示例仅取消该容器的 AppArmor 限制，可替换为允许所需挂载的受审查本地策略。容器不会运行游戏。

### TLS certificate and pin / TLS 证书与指纹

Remote HTTP is refused: supply your own PEM certificate and private key. The certificate SAN must contain the exact DNS name or IP used by clients. Example **documentation-only** self-signed certificate (replace reserved example names/IP):

远程 API 强制 TLS，证书 SAN 必须包含客户端使用的域名或 IP。以下仅为生成示例，请替换示例域名和保留地址：

```sh
mkdir -m 700 tls
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
  -keyout tls/server.key -out tls/server.crt \
  -subj '/CN=games.example.invalid' \
  -addext 'subjectAltName=DNS:games.example.invalid,IP:192.0.2.10' \
  -addext 'extendedKeyUsage=serverAuth' \
  -addext 'keyUsage=critical,digitalSignature,keyEncipherment' \
  -addext 'basicConstraints=critical,CA:FALSE'
chmod 600 tls/server.key
```

For macOS TLS validation, retain **SAN**, **EKU `serverAuth`**, **key usage `digitalSignature,keyEncipherment`** (this RSA example), and **`CA:FALSE`** when regenerating the leaf certificate. CN alone is insufficient. Inspect the resulting certificate with `openssl x509 -in tls/server.crt -noout -text`; the example uses RSA-3072, SHA-256 and a 365-day lifetime. These extensions make it suitable for server authentication; a self-signed certificate still requires explicitly verified per-server trust/pinning. A pin must not bypass hostname, validity, certificate-purpose or TLS checks. See [Apple TLS certificate requirements](https://support.apple.com/en-us/103769) and [OpenSSL extension configuration](https://docs.openssl.org/3.3/man5/x509v3_config/).

macOS 验证要求重新生成时保留 SAN 和 `serverAuth` EKU；本 RSA 示例还明确设置 `digitalSignature,keyEncipherment` 及 `CA:FALSE`，不能仅靠 CN。用上述命令检查实际证书扩展。自签证书仍需核验后配置该服务器专属信任/pin，不能跳过主机名、有效期、证书用途或 TLS 校验。重建证书会改变 DER 指纹，须核对并更新 pin，再重新下载邀请文件。

Set `GAMESHELF_TLS_DIR` to the absolute directory containing `server.crt` and `server.key`. The process uses `GAMESHELF_TLS_CERT`/`GAMESHELF_TLS_KEY` (Compose sets `/tls/server.crt` and `/tls/server.key`). It never disables certificate verification. Use a publicly trusted or private-CA certificate for normal browser administration. For a self-signed certificate, verify its fingerprint separately and configure **only that server's** pin in the client; no global trust-all or wildcard CORS. The pin is SHA-256 of the **leaf certificate DER**, lowercase hex, without colons (not an SPKI hash):

浏览器管理建议使用受信任 CA 证书。自签证书应通过独立可信渠道核对指纹，再填入客户端该服务器专属 pin，不使用全局信任。指纹为叶证书 DER 的 SHA-256 小写十六进制，无冒号：

```sh
# In the running container / 容器内
# All docker compose commands here run from Server/.
docker compose exec gateway python -m gameshelf_server cert-fingerprint
# Or locally; no service configuration required / 本地也可独立计算
python3.12 -m gameshelf_server cert-fingerprint /absolute/path/to/server.crt
```

Certificate renewal changes this pin. Deliver the replacement fingerprint through a trusted channel before reconnecting. A TLS reverse proxy can connect to a **loopback-only** HTTP listener in the same network namespace; the service does not trust forwarded headers or allow a public cleartext upstream. Default Compose terminates TLS directly. Set `GAMESHELF_PUBLIC_ORIGIN` to the exact external HTTPS origin without trailing slash if a proxy changes Host.

证书更新会改变 pin，需可信核验后更新。反向代理的明文上游仅支持同一网络命名空间的回环监听；默认 Compose 直接提供 TLS，不信任转发头。代理改写 Host 时设置精确的 `GAMESHELF_PUBLIC_ORIGIN`。

### Bootstrap / 初始化管理员

Create a password file **outside the repository and source/state mounts**, using hidden input. Point `GAMESHELF_BOOTSTRAP_PASSWORD_FILE` in `.env` to it and choose `GAMESHELF_BOOTSTRAP_USERNAME`. The file is a Docker secret, read only when the users table is empty. No password environment variable, command argument or request log is used.

在仓库及源/状态挂载之外创建私有密码文件；密码通过隐藏输入读取，不能作为命令参数。首次空数据库才使用该 Docker secret，不会重置已有账号：

```sh
python3 - <<'PY'
import getpass, os
from pathlib import Path
path = Path(input('Private password file absolute path: '))
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(getpass.getpass('Initial administrator password (12+ chars): '))
PY
docker compose build
docker compose up -d
# Create another admin interactively, or bootstrap a service with no initial users.
# 在线创建管理员：仅容器 root 的 0600 Unix socket，不发送到远程 HTTP。
docker compose exec gateway python -m gameshelf_server create-admin
```

`create-admin` prompts for username and password twice. In a running container it calls a root-private local Unix socket; no arbitrary command or filesystem API exists. Offline it takes the exclusive SQLite state lock. Run a single gateway per state volume. Do not start multiple Samba/gateway processes inside one container.

`create-admin` 交互读取用户名及两次密码，在线通过 root 专属 Unix socket 创建；离线使用独占状态锁。同一状态卷只允许一个网关进程。

## Client invitation / 客户端连接邀请

After signing in to the admin page, select **Download invitation / 下载邀请**. It downloads `gameshelf-invitation.json` matching `SharedServerInvitation` version 1. Share this file so users can import the address, name and optional certificate pin; they still sign in with their own account/password. The file contains public connection information only, never HTTP tokens, passwords, SMB credentials, account IDs or source paths.

管理员登录后点击「下载邀请」，将文件交给普通用户导入；用户无需手填服务器名称、地址和可选证书指纹，账号密码另行登录。邀请不是访问凭据。

Configure and restart the service:

```dotenv
GAMESHELF_SERVER_NAME=GameShelf
GAMESHELF_PUBLIC_ADDRESS=https://games.example.invalid:8787
GAMESHELF_CERTIFICATE_SHA256=
```

`GAMESHELF_PUBLIC_ADDRESS` must be the client-reachable **HTTPS root URL**, without credentials, path, query or fragment. If unset, the service can use the explicitly configured `GAMESHELF_PUBLIC_ORIGIN`; it never infers an invitation address from `Host`, `Forwarded` or `X-Forwarded-*`. If neither address is configured, export returns 503. `GAMESHELF_CERTIFICATE_SHA256` is optional: leave empty for normal CA verification, or provide the SHA-256 of the **public TLS endpoint's leaf certificate DER** for per-server pinning. Hex case and colon separators are normalized. Use the existing `cert-fingerprint` command with the relevant certificate; if a proxy terminates TLS, use its public certificate, not the backend certificate. Renewed certificates require a fresh pin and invitation.

公开地址必须是客户端可访问的 HTTPS 根地址；未单独配置时仅回退到已配置的 `GAMESHELF_PUBLIC_ORIGIN`，不采信请求 Host 或转发头。受信任 CA 证书可不填 pin；自签证书填写公开 TLS 端点的叶证书 DER SHA-256，证书更新后重新生成邀请。反向代理终止 TLS 时使用代理公开证书的指纹。

API: **`GET /api/admin/invitation`**, Bearer administrator token required. Response uses `Content-Disposition: attachment; filename="gameshelf-invitation.json"` and `Cache-Control: no-store`. Non-admin accounts receive 403; unauthenticated requests receive 401. The JSON is at most 4096 UTF-8 bytes:

```json
{"version":1,"address":"https://games.example.invalid:8787","name":"GameShelf"}
```

An explicitly configured pin adds only `"certificateSHA256":"<64 lowercase hex characters>"`. The UI adds a single download action; configuration remains with the operator.

## Administration and saves / 管理与存档

Open `https://your-gateway:8787/`, sign in as admin, then:

1. Register an allowed container source, such as `/sources/library`.
2. Scan. Review candidate entrances and **seed-save exclusions**.
3. Add explicit `savePaths` rules for unfamiliar games, select candidates and publish.
4. Create accounts; grant each published edition explicitly. Admin status alone grants no game access.

打开 HTTPS 管理页：添加容器内只读源→扫描→检查候选入口及源存档排除规则→勾选发布→创建账号→逐游戏授权。管理员不会自动获得游戏访问权限。

**Seed-save privacy:** source game-relative saves must not become new users' starting progress. Defaults exclude root `save`, `saves`, `savedata`, `game/saves`, `www/save`, and files ending `.sav/.save/.rpgsave/.rmmzsave` or named `SaveNN.rxdata/rvdata/rvdata2` (case-insensitive). Generic `.dat`, `.json`, `.rvdata2` assets are **not** excluded. Rules matched through internal links also exclude their canonical targets. Administrator rules supplement defaults:

**初始存档隐私：** 默认遮蔽上述已知存档，不屏蔽通用资源扩展名。无法自动识别所有引擎自定义文件名，发布前必须审查并补充规则；没有“任意游戏都能自动识别存档”的保证。

```json
{"savePaths":[{"path":"custom-progress.dat","kind":"file"},{"path":"player-state","kind":"directory"}]}
```

Publish accepts this JSON at `POST /api/admin/candidates/{id}/publish`; UI offers the same additional-rule editor. Rules are immutable per edition. Changed rules produce a new game ID and a fresh private workspace, never an in-place reset/migration. The API returns `detectedSavePaths` on candidates and `savePaths`/`saveIsolation` on games. A private overlay first hides seed saves using whiteouts and opaque empty directories. A root-private initialization manifest outside the exported share preserves the user's own progress on reopen. A missing/mismatched manifest on an existing upper refuses export; **do not delete manifests to repair a live workspace**. No owner's progress is migrated.

发布接口接受上述 JSON，管理页有对应编辑框。规则变化产生新版本 ID 和全新私有目录，不重置旧进度。首次 overlay 使用白化文件及不透明空目录遮蔽源存档；初始化标记保存在共享之外，后续不再清空账号存档。已有 upper 的标记丢失或冲突时拒绝导出，切勿删除标记强行修复。

The reserved `.gameshelf-profile` directory is created inside the account/game overlay; a source containing that name is rejected. Client-local Wine links may target real network directories such as `.gameshelf-profile/WindowsUsers/Player`; the stable Player directory avoids splitting progress across Mac login names. Public and Default remain separate; registry/prefix runtime data stays client-account-private. Internal source symlinks are strictly resolved, including chains: broken/cyclic/outside/special-file targets are rejected. Absolute internal links are rewritten **only in the private overlay**. Source root and ancestor symlinks remain forbidden. Samba follows only links contained in the share (`wide links=no`); guest and SMB1/2 are disabled, SMB3 encryption required.

`.gameshelf-profile` 为账号/游戏私有目录，源中同名目录会被拒绝。支持内部安全链接及 Ren’Py `.app` 框架链接；越界、循环、悬空及特殊文件链接均拒绝。源根及祖先不能是软链接。Wine 的链接位于客户端本地，服务端 profile 是真实目录。未知 native 游戏仍需要客户端支持的存档适配器，不承诺通用 native 隔离。

OverlayFS uses `metacopy=on,redirect_dir=on,index=off`; `redirect_dir=off` conflicts with metacopy on supported Linux kernels. Keep lower/upper layers trusted and root-managed: handcrafted overlay xattrs in imported state are unsafe. Samba still confines links with `wide links=no`, and clients cannot set `trusted.*` xattrs. The dedicated smbd has its own process session so shutdown cannot signal the API/test runner. OverlayFS metacopy prepares ownership/modes without copying all game contents; modifying a large archive can still copy that archive into server upper. No whole-game fallback is downloaded to clients. Immutable source checking uses bounded **metadata** signatures (paths, sizes, modes, mtimes and links), not full file hashes: a hostile host can alter bytes while preserving metadata. Treat source administration as trusted. Keep new editions separate; no runtime source mutation or auto-migration is supported. Scan is bounded and synchronous for its requesting admin, but its filesystem walk does not hold the SQLite authority lock or block other players’ heartbeats. One scan runs at a time; admin authorization and root identity are checked again before a short atomic commit. An unavailable source is retained and returns 503, not deleted.

metacopy 仅准备私有元数据；修改大文件仍会在服务器发生整文件 copy-up。源版本检查基于有界元数据签名而非全文件内容哈希；管理员须可信并冻结已发布源。扫描对发起者同步，但遍历不持有状态锁，不阻塞其他玩家心跳；提交前重新检查管理员权限和源根身份。同一时间仅运行一个扫描。离线源保留记录并报 503。

## Shared WebKit / 共享 WebKit

A desktop RPG Maker MZ package can offer WebKit only when its five metadata/script SHA-256 fingerprints exactly match the tested `MZWebProfile.sakura` profile shared with the client. Recognition also requires a regular `index.html` and a valid MZ-header `Game.exe`. The gateway reads at most 2 MiB per profile file, follows no root/ancestor/profile symlinks, and does not hash game assets. A match puts `{path:"index.html",backend:"rpgmz",engine:"RPG Maker MZ"}` first, then preserves Wine entrances, language ordering and distinct platform/version directories. Unknown or modified desktop NW.js packages keep eligible Wine entrances and are not silently converted into browser games.

共享 WebKit 仅对已验证的 MZ profile 开放：五个元数据/脚本哈希须与客户端 `MZWebProfile.sakura` 完全一致，并具备普通文件 `index.html` 和带 MZ 头的 `Game.exe`。每个 profile 文件最多读取 2 MiB，不跟随根、祖先或 profile 文件软链接，不读取游戏资源来做哈希。命中后优先提供 `index.html / rpgmz / RPG Maker MZ`；Wine、翻译入口和平台/版本目录均保留。未知或修改过的 NW.js 桌面包不会自动启用 WebKit。

Use a client with the shared WebKit save adapter, which keeps WebKit progress private to the server/account/game. Unknown shared web/native engines remain explicitly unsupported unless a separate supported save adapter exists. This is profile-specific support, not support for arbitrary Node plugins or all MZ games. For an already published unchanged edition, rescan and **select it for publication again** to refresh its entrances; the game ID, grants and private state remain intact. Scanning alone does not change the catalog.

使用具备共享 WebKit 存档适配器的客户端，进度按服务器/账号/游戏隔离。未知共享网页/native 引擎仍需明确的适配器；此规则不代表支持任意 Node 插件或所有 MZ 游戏。旧版本仅新增识别能力时，可重扫后再次勾选发布以更新入口，保留游戏 ID、授权和私有进度；仅扫描不会改变已发布目录。

## Client API / 客户端接口

See `api-schema.json` for all paths and schemas. Responses are JSON, errors `{ "error": { "code": 403, "message": "…" } }`. All IDs are opaque strings; `expiresAt` is Unix seconds as a JSON number. Bearer tokens expire (24 h default), are stored SHA-256 hashed and are unrelated to SMB credentials. Account passwords use random-salted PBKDF2-SHA256, 600,000 iterations. No wildcard CORS/cookies. Default global login throttle: 30 attempts/minute.

- `POST /api/login {username,password}` → `{token,expiresAt,user:{id,username,admin},serverID}`.
- `GET /api/catalog` → `{games:[{id,title,entries:[{path,backend,engine}],savePaths,saveIsolation}]}`; only granted games, no source paths.
- `POST /api/games/{id}/session {deviceID}` → `{leaseID,expiresAt,serverID,userID,game,profileKey,share:{host,port,name,username,password}}`.
- `POST /api/sessions/{leaseID}/heartbeat {}` → `{leaseID,expiresAt}`. Default TTL 90 s; heartbeat every 25 s.
- `DELETE /api/sessions/{leaseID}` → `{}`. Unmount client NetFS first; 503 means closure pending, not released.
- `POST /api/logout {}` revokes **only the current** token and leases created with it; other clients and browser logins are unaffected. Grant revoke/account disable also close affected shares.

Token 仅用于 HTTP，NetFS 必须使用响应中的独立 SMB 用户名和密码，不放入 URL。稳定本地身份按 server/account/game 分区。90 秒租约建议每 25 秒心跳；释放前先卸载 NetFS。409 表示已有有效写租约；503 表示共享关闭/挂载卸载尚未完成，不能当作已释放。退出只撤销当前 token 及其创建的租约，不影响同账号其他客户端/浏览器。

Expiry/revocation removes the SMB identity, removes/reloads the share, closes active share connections and performs a **normal unmount** (never lazy/force). A failed step keeps the lease locked in `revoking` and the reaper retries; no reassignment is permitted until the barrier succeeds. Startup reconciles stale leases before listening. If a client holds the old mount busy, exit the game and unmount it, then retry; never bypass the DB lease or delete upper/work. Container shutdown stops its own Samba only.

过期/撤销先删除 SMB 身份、移除并重载共享、关闭旧连接，再正常卸载；任一步失败都保留锁并重试，不能仅凭数据库时间戳转交写权限。启动时先清理旧租约，再开放 API。不得强制/延迟卸载或手工删除 upper/work。

## Validation / 验证

Latest evidence: the local Python 3.12 suite ran 63 tests (62 passed, one opt-in Linux test skipped). The deployment operator separately reported the refreshed opt-in Linux test **passing: 1 test, 9.796 seconds, OK**. Its two intentional busy-handle close attempts returned EBUSY as expected and blocked reassignment; they were not test failures. Independent deployed HTTPS/certificate-pin and macOS NetFS validation remain the next phase.

最新验证：本地 63 项测试中 62 项通过，1 项 Linux 集成默认跳过；部署操作者另行报告真实 Linux 集成 1 项通过（9.796 秒，OK）。其中两次 EBUSY 为主动持有句柄的屏障测试预期结果。独立部署 HTTPS/证书 pin 与 macOS NetFS 尚待下一阶段验证。

Unprivileged local suite (Python 3.12; local HTTP/Unix socket access required):

```sh
python3.12 -m unittest discover -s tests -v
```

Real Linux integration is **opt-in** and uses only generated scratch games. It requires a **separate empty ext4 bind directory with searchable ancestors (0711; no directory listing)**, not production state or real source; no network/NAS access or host port mapping is needed. Build the image, then have the deployment operator run (override base with `--build-arg PYTHON_IMAGE=python:3.12-slim` if using an existing trusted cache):

真实 Linux 集成测试仅显式开启，使用临时合成游戏；需独立空 ext4 目录，不能使用生产状态或真实游戏源。测试目录及祖先需允许普通 uid 穿越（0711，不允许列目录）。由部署操作者运行，不暴露端口、不联网、不挂载宿主 Samba：

```sh
docker build -t gameshelf-gateway-test .
docker run --rm --network none --cap-drop ALL \
  --cap-add SYS_ADMIN --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETUID --cap-add SETGID --cap-add MKNOD --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges:true --security-opt apparmor:unconfined \
  --mount type=bind,src=/absolute/empty-ext4-test-dir,dst=/test-state \
  -e GAMESHELF_LINUX_TESTS=1 -e GAMESHELF_INTEGRATION_DIR=/test-state \
  --entrypoint python gameshelf-gateway-test \
  -m unittest discover -s tests -p test_linux_integration.py -v
```

Checks real encrypted SMB reads/writes/rename/delete, internal links, Alice/Bob seed-save privacy and reopening, unchanged source hashes, grants, old credentials and an actual busy-mount reassignment barrier. Same-device bind mounts are identified through `/proc/self/mountinfo`, not `os.path.ismount`. A failed unmount preserves scratch rather than deleting through a live mount; cleanup diagnostics never replace the original test failure. Kernel/SMB/macOS compatibility and sparse NetFS reads must still be verified in deployment; a passing injected-driver suite is not that evidence.

覆盖真实加密 SMB、copy-up/删除/重命名、内部链接、双账号源存档遮蔽及重开保持、源哈希不变、授权、旧凭据失效和真实忙碌挂载屏障。卸载失败时保留测试目录，不穿过活挂载删除。仍需部署方验证目标内核、macOS NetFS 稀疏读取及实际游戏适配。
