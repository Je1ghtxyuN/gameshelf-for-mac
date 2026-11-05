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

### First administrator / 首位管理员

Default Compose starts without a preset account. Configure `GAMESHELF_PUBLIC_ADDRESS` (or `GAMESHELF_PUBLIC_ORIGIN`) and optionally `GAMESHELF_CERTIFICATE_SHA256`; these are the same verified HTTPS address and leaf pin used by client invitations. An empty service writes **`/state/administrator-setup.json`**, mode **0600**, containing version 1, `kind: "administrator-setup"`, address, optional name/pin, and a random one-use `setupToken`. Retrieve that file privately from the dedicated state directory and import it in the client setup flow, or select it on the HTTPS admin page to choose your username/password. No URL fragment, command argument or log carries the capability. Do not share it as a normal invitation or commit it. The admin page keeps credentials in memory.

默认 Compose 不预置账号。配置公开 HTTPS 地址及可选证书 pin，空服务在专用状态目录生成权限 0600 的 `administrator-setup.json`。通过私有渠道取出并导入客户端初始化流程，或在 HTTPS 管理页选择该文件后设置管理员用户名和密码。此文件包含 `kind: "administrator-setup"` 和一次性初始化权限，不是普通连接邀请，不能公开或提交。账号建立后能力立即失效并删除文件；已有账号（包括停用账号）的服务不会重新开放认领，也不会重置密码。

`GET /api/server-info` includes `setupRequired`. `POST /api/setup` accepts `{setupToken,username,password}` and returns the existing login response. The first-administrator check, account creation and capability consumption run in one SQLite transaction; concurrent claims yield one success and 409 for others. Failed validation retains the invitation. The file stays stable across restarts with unchanged public configuration. Missing public address leaves setup unavailable until configured; no request Host is used. For self-signed TLS, verify the fingerprint privately before using the invitation.

```sh
docker compose build
docker compose up -d
# Retrieve administrator-setup.json from the private host state directory.
# 仅通过私有渠道取出宿主专用状态目录中的初始化邀请。
# Optional interactive administrator creation; password uses hidden input:
docker compose exec gateway python -m gameshelf_server create-admin
```

Existing password-file bootstrap remains available through the optional override `compose.bootstrap.yaml`. Set `GAMESHELF_BOOTSTRAP_USERNAME` and `GAMESHELF_BOOTSTRAP_PASSWORD_FILE` to an external 0600 secret file created with hidden input, then run `docker compose -f compose.yaml -f compose.bootstrap.yaml up -d`. Password-file bootstrap is only used on an empty database; no password environment variable or argument exists. An initialized state needs neither setup invitation nor bootstrap secret.

原有密码文件初始化可通过 `compose.bootstrap.yaml` 可选覆盖文件使用。密码文件放在仓库及源挂载之外，用隐藏输入创建；只有空数据库才读取。已有状态无需初始化文件或密码 secret。

`create-admin` prompts for username/password, using the running container's root-private Unix socket or an offline exclusive state lock. Run one gateway per state volume. Self-admin `POST /api/admin/users/{id}/rename {username}` changes only your login name, retaining account ID, password, tokens, roles, grants, leases and private metadata. It cannot rename another account.

`create-admin` 在线使用 root 专属 Unix socket，离线使用独占状态锁；同一状态卷只运行一个网关。管理员仅能通过 rename 接口修改自己的用户名；原账号 ID、密码、角色、令牌、授权、租约和个人数据保留。

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

## Private metadata and covers / 私有元数据与封面

Authenticated `GET /api/personal-library` lists only the caller's libraries. `GET/POST /api/personal-library/{deviceUUID}` reads or atomically updates one revisioned snapshot. A missing library GET returns 404; the first POST uses expectedRevision 0. POST is `{expectedRevision,snapshot}`; success returns `{deviceID,revision,snapshot}` with revision incremented, while a stale revision returns 409 without changing data. A snapshot contains only game UUID/title/favorite/collection UUIDs/playtime/optional last-played and collection UUID/name. No launch paths, programs, resources or saves are accepted. Other administrators cannot access it through their account APIs. See `api-schema.json` for exact fields and limits.

个人库 API 仅按当前登录账号隔离，管理员也不能选择其他账号。未建立的个人库 GET 返回 404，首次 POST 使用 expectedRevision 0；冲突返回 409，不能静默覆盖。只接受标题、收藏、分组与时长等元数据，不上传路径、程序或存档。快照最多 512 KiB、1000 个游戏、200 个分组，标题最多 1024 UTF-8 字节，分组名最多 240 UTF-8 字节，数值必须有限且非负，playtimeSeconds 最大 31557600000。未知字段、重复 UUID 或无效分组引用均拒绝。

Personal `GET/POST /api/personal-library/{deviceUUID}/covers/{gameUUID}` is separate from snapshot revisions. POST accepts `{data:base64JPEG}`; GET and POST return `{data,mime:"image/jpeg",sha256}`. Canonical defaults use administrator-only `POST /api/admin/games/{gameID}/cover` and explicitly granted `GET /api/games/{gameID}/cover`. Catalog entries optionally include `coverSHA256`. Personal covers never overwrite these defaults. The admin page uploads default JPEG covers for already-published games; uploading a cover does not publish a game or create grants.

封面独立接口统一接收 base64 JPEG JSON，返回图像、MIME 与 SHA-256。个人覆盖仅属于当前账号/设备/游戏，默认封面只允许管理员写入、已授权账号读取。管理页仅为已发布游戏上传默认封面；不会自动发布或授权。

Decoded covers are at most 256 KiB; JPEG marker structure is checked, restricted to 8-bit baseline/extended/progressive, 1/3 components and dimensions at most 2048×2048. This standard-library check does not fully decode image pixels; clients must handle decoder rejection. Snapshots/covers are stored transactionally in gateway SQLite, outside all game sources. No image subprocess, filesystem selector, symlink traversal or browser database is involved. Ordinary requests retain a 16 KiB body limit; only the exact snapshot route permits 512 KiB + 1024 bytes, and exact cover routes permit 350552 bytes of base64 JSON. Malformed/nonfinite/duplicate-key JSON is rejected. Validation or CAS failure leaves prior data intact.

封面解码后最多 256 KiB，仅接受规定的 JPEG 标记结构与尺寸；标准库校验不等于完整像素解码，客户端仍需处理坏图。快照及封面通过 SQLite 原子事务保存，不进入源目录。普通请求仍限 16 KiB，只有对应快照及封面路由放宽；非法 JSON、非有限数与重复键拒绝，失败不会改变已有记录。

UUID inputs accept uppercase/lowercase hyphenated strings; responses normalize device/game/collection UUIDs to lowercase. Personal-library envelopes remain exactly `{deviceID,revision,snapshot}`; the HTTP token defines the account namespace.

UUID 接受大小写带连字符格式，响应统一为小写。个人库响应仍仅含 deviceID、revision、snapshot；账号范围由 HTTP token 决定。

### Account storage bounds / 账号存储上限

Each account may store at most **8** device libraries. `GET /api/personal-library` retains the full-snapshot contract and is limited to **4 MiB of the actual UTF-8 HTTP JSON**, including escaping, spaces and envelopes. Metadata CAS checks the prospective full response before commit; exceeding either quota returns **413** without changing the snapshot, revision or covers. Listing fetches at most nine small device descriptors before loading any snapshot, and each snapshot read is bounded separately. Existing legacy overquota accounts receive 413 rather than silent truncation/deletion; individual device reads remain available for operator-assisted recovery. Cover writes on legacy accounts above the eight-library cap also return 413.

每账号最多 **8** 个设备库，完整快照列表按实际 HTTP JSON 编码最多 **4 MiB**，包括转义、空格及响应封装。CAS 提交前检查新状态，超限返回 **413** 并回滚快照、版本与封面清理。读取列表先限制为最多九条小型设备记录，不读取全部快照。旧版超限数据不会自动删除或截断，单设备读取仍可用于管理员协助处理，超过八库的旧账号封面写入也返回 413。

Personal cover GET/POST requires an existing device library and a game UUID present in that account’s current snapshot; unknown device/game returns **404**. Metadata must therefore be uploaded first. Matching UUIDs in another account grant no access. Updating metadata atomically prunes removed games’ cover blobs within the same CAS transaction. With at most 1000 games/library, new cover rows are bounded by 8 × 1000 per account; each image remains at most 256 KiB. Default published-game covers use their separate unchanged authorization routes.

个人封面 GET/POST 必须先有本账号的设备库及快照内游戏；未知对象返回 **404**，须先上传元数据。其他账号即使使用相同 UUID 也无法访问或插入。元数据移除游戏时，在同一次 CAS 事务中删除对应封面。每库最多 1000 个游戏，因此每账号新增封面记录最多 8 × 1000，每张仍限 256 KiB；已发布游戏的默认封面接口不变。

### Storage mount readiness / 存储挂载

Restore the configured storage volume before starting the gateway. Compose binds the existing certificate and key files individually with host-path creation disabled, so an absent volume fails before application startup instead of creating placeholder directories and fresh state. Keep the state directory on its original filesystem; reconnecting an empty mount-point directory is not a replacement for restoring that filesystem.

共享服务启动前应先恢复配置的存储卷。Compose 分别绑定已存在的证书和密钥文件，并关闭自动创建主机路径；存储卷缺失时会在启动应用前失败，避免创建占位目录和新状态。运行数据应保留在原文件系统，空的挂载点目录不能替代原存储卷。

For an explicitly pinned endpoint, the Mac client establishes a direct TLS 1.2+ connection and checks the exact leaf fingerprint, hostname and validity. This avoids changing system trust or weakening the app’s global transport policy. An endpoint using normal CA validation continues through the system URL session and proxy policy; a pinned endpoint must be directly reachable from the client.

显式绑定证书的端点使用直接的 TLS 1.2+ 连接，检查叶证书指纹、主机名与有效期，不修改系统信任或应用全局传输策略。普通 CA 验证的端点继续使用系统网络会话及代理策略；绑定证书的端点需要客户端能够直接到达。
