# TOSAppSelfTestingTool 调用操作指南

- 版本：v1.0.0
- 适用设备：TOS（NAS，已安装 DockerEngine）
- 工具定位：应用包自测工具 —— 对 deb / docker 应用包做规范检测，并可将 docker 应用包直接安装到设备上验证

---

## 1. 快速上手

```bash
# 1) 检测一个应用包（只做检测，不改动任何东西）
./TOSAppSelfTestingTool -c docker_qbittorrent.tar.gz

# 2) 检测 + 安装一步完成（-i 自带检测：先检测，通过才安装，有问题即终止；需 root）
./TOSAppSelfTestingTool -i docker_qbittorrent.tar.gz

# 3) 查看版本 / 帮助
./TOSAppSelfTestingTool -v
./TOSAppSelfTestingTool -h
```

检测通过只输出一行 `检测通过`；有问题会逐条列出（详见第 3 节）。`-i` 是"检测 + 安装"一条流程：自带检测、带百分比进度条，检测通过才继续安装（详见第 4 节）。

## 2. 命令总览

```
$ ./TOSAppSelfTestingTool -h
应用包规范检测与安装 TOSAppSelfTestingTool

用法:
  -c, --check <路径>    只对包做检测(文件合法性与参数合法性): 过程中不中断, 问题逐条列出,
                        无问题输出「检测通过」
                        支持的路径形态: deb 成品(.deb) / docker 成品(应用 .tar.gz) / 打包前的应用目录
  -i, --install <包>    安装应用包: 先做规范检测, 发现首个问题即终止; 通过后按 compose 流程
                        安装到 DockerEngine 所在卷(自动探测), 过程逐步输出百分比(需 root)
                        目前仅支持 docker 应用包(.tar.gz); deb 与目录形态暂不支持安装
  -v, --version         显示版本号
  -h, --help            显示本用法

退出码: 0 通过/安装成功 / 1 存在阻断项或安装失败 / 2 未能完成检测(用法或环境问题)
```

**通用规则**

- 第一个参数必须是 `-c/--check`、`-i/--install`（或 `-v/-h`）；不带参数直接运行会提示：

```
必须选择一个操作: -c/--check 或 -i/--install
（后跟用法说明）
```

- `check` 和 `install` 都没有其它选项

**退出码含义**

| 退出码 | 含义 |
|---|---|
| 0 | 检测通过 / 安装成功 |
| 1 | 存在阻断项 / 安装失败 |
| 2 | 没能完成（命令用法错误或设备环境问题，与包本身无关） |

## 3. `-c/--check`：检测应用包

### 3.1 支持的三种路径

| 形态 | 示例 | 说明 |
|---|---|---|
| deb 成品 | `-c yourapp_1.0.0_amd64.deb` | 完整检测：文件内容 + deb 包格式（解包、元数据一致性等） |
| docker 成品 | `-c docker_qbittorrent.tar.gz` | 完整检测：文件内容 + 包结构 |
| 打包前的应用目录 | `-c ./my_app/` | 检测目录内容（config.ini 字段、图标、语言文件、compose、服务配置等），不涉及包格式 |

### 3.2 输出说明（以下均为设备上真实运行样例）

**① 全部通过**（只输出一行，退出码 0）：

```
$ ./TOSAppSelfTestingTool -c docker_AdGuardHome-v0.107.77.tar.gz
检测通过
```

**② 存在阻断项**（不中断检测，全部问题逐条列出，退出码 1）：

```
$ ./TOSAppSelfTestingTool -c bad_docker.tar.gz
ERROR [C10] config.ini: 缺少必填字段 relation
ERROR [C25] config.ini: docker 应用 relation 必须填写 docker 和 DockerEngine
检测未通过: 阻断项 2 / 提示项 0
```

**③ 仅有提示项**（不算不通过，退出码 0）：

```
$ ./TOSAppSelfTestingTool -c warn_docker.tar.gz
WARN  [D20] extra.txt: 包内含额外顶层条目(规范仅需 config.ini/<app_id>.lang/docker-compose.yml 与图标; 若为应用运行时文件请确认是否应打入包内)
检测通过: 提示项 1
```

**④ 检测打包前的应用目录**：

```
$ ./TOSAppSelfTestingTool -c /project/my_app/
检测通过
```

**⑤ 检测设备上已安装的应用目录**（会附加一条提示）：

```
$ ./TOSAppSelfTestingTool -c /Volume1/@apps/DockerEngine/application/AdGuardHomeDocker
检测通过
提示: 该目录是已安装形态(非打包前目录): 安装流程会改写 config.ini 并解开 webui, 异常项反映安装后布局, 不代表包本身不合规
```

（该提示只作说明、不改变判定 —— 已安装应用的 config.ini 被安装流程改写、webui 被解开，属于正常的安装后布局。）

### 3.3 注意事项

- 检测是**只读**的：不安装、不构建、不修改被检对象
- 检测 deb 包需要宿主有 `xz`/`zstd` 解压工具（缺失时会明确提示"环境缺少解压工具"，这是环境问题、不是包的问题）

## 4. `-i/--install`：安装 docker 应用包

### 4.1 支持范围与前置条件

- **仅支持 docker 应用包（`docker_*.tar.gz`）**；传入 deb 或目录会直接提示（退出码 2）：

```
$ ./TOSAppSelfTestingTool -i yourapp_1.0.0_amd64.deb
yourapp_1.0.0_amd64.deb 是 deb 成品: 当前版本 install 仅支持 docker 应用包(.tar.gz), deb 安装暂未支持
```

- 需 **root** 运行
- 设备需已安装 DockerEngine；安装位置自动探测（DockerEngine 所在卷），无需也无法手动指定
- 安装目录：`<卷>/@apps/DockerEngine/application/<app_id>`（app_id 取自包内 config.ini）

### 4.2 执行流程（单条进度流，每步带百分比 + 进度条）

```
$ ./TOSAppSelfTestingTool -i docker_AdGuardHome-v0.107.77.tar.gz
[ 10%] [##------------------] 解压应用包 → /Volume1/@apps/DockerEngine/application/.install-staging-AdGuardHomeDocker-14806
[ 20%] [####----------------] 检测文件完整性
[ 25%] [#####---------------] 检测字段合法性
[ 35%] [#######-------------] 检查 compose 项目名 adguardhome
[ 41%] [########------------] 落地安装目录 → /Volume1/@apps/DockerEngine/application/AdGuardHomeDocker
[ 48%] [#########-----------] 写入 docker-compose.yml
[ 62%] [############--------] 拉取镜像并同步共享目录权限
[ 77%] [###############-----] 创建容器
[ 83%] [################----] 更新应用访问路径与安装数据
[ 91%] [##################--] 执行安装后处理 (post-install)
[100%] [####################] 启动容器
安装完成: AdGuardHomeDocker, compose 项目 adguardhome, 安装目录 /Volume1/@apps/DockerEngine/application/AdGuardHomeDocker
```

流程分两段：

1. **检测段**（10%–25%）：先把包解压到暂存目录做完整检测 —— 通过则静默继续；**发现首个问题立即终止且不触碰已有安装**（样例见下）
2. **安装段**（35%–100%）：检测通过后才落地到正式安装目录（覆盖旧安装），随后按 compose 流程安装、启动

**检测未通过时（fail-fast，只提示首个问题）**：

```
$ ./TOSAppSelfTestingTool -i bad_docker.tar.gz
[ 10%] [##------------------] 解压应用包 → /Volume1/@apps/DockerEngine/application/.install-staging-AdGuardHomeDocker-14819
[ 20%] [####----------------] 检测文件完整性
[ 25%] [#####---------------] 检测字段合法性
ERROR [C10] config.ini: 缺少必填字段 relation
检测未通过, 终止安装
```

### 4.3 安装后处理（自动完成，与应用中心行为一致）

- compose 项目名已被占用时自动避让（`xxx` → `xxx_1`），并同步改写 config.ini 与 compose
- 容器名与现存容器重名时自动避让
- 容器以非 root 用户运行时，自动把挂载目录/共享目录的属主改为该用户，避免应用运行时报权限错误
- 从 compose 的 `x-app-meta.web` 读取访问端口，写回 config.ini 的访问路径
- 写入安装数据，安装后的应用可被应用中心正常识别

### 4.4 失败行为

| 失败阶段 | 提示与残留 |
|---|---|
| 检测发现阻断项 | 输出首个错误 + `检测未通过, 终止安装`；不触碰已有安装 |
| 拉取镜像失败（62%） | 输出单行错误后**直接终止**（不再继续创建容器）；解压目录已删除 |
| 创建容器失败（77%） | 输出单行错误；解压目录已删除 |
| 启动容器失败（100%） | 输出单行错误 + `安装完成(未启动): ...`；**保留安装目录**，可排查后手动启动 |
| 安装后处理失败（91%） | 输出单行错误；保留安装目录，不启动容器 |

拉取镜像失败的输出样例（网络不可用时）：

```
[ 62%] [############--------] 拉取镜像并同步共享目录权限
安装失败: Error response from daemon: failed to resolve reference "docker.io/adguard/adguardhome:v0.107.77": failed to do request: Head "https://registry-1.docker.io/v2/adguard/adguardhome/manifests/v0.107.77": Service Unavailable
```

> 所有失败提示都只输出错误本身（不夹带过程噪声）；`安装失败:` 之后即 docker / 系统的原始错误内容。

## 5. 常用操作示例（设备上）

```bash
# 查看版本
./TOSAppSelfTestingTool -v

# 交付前检测：按三种形态任选其一
./TOSAppSelfTestingTool -c /path/docker_qbittorrent.tar.gz
./TOSAppSelfTestingTool -c /path/yourapp_1.0.0_amd64.deb
./TOSAppSelfTestingTool -c /path/源码应用目录/

# 安装 docker 应用包并观察进度（需 root）
./TOSAppSelfTestingTool -i /path/docker_qbittorrent.tar.gz

# 覆盖安装：对同一个包再执行一次即可（旧安装目录会被清理后重装）
./TOSAppSelfTestingTool -i /path/docker_qbittorrent.tar.gz

# 检测设备上已安装的应用目录
./TOSAppSelfTestingTool -c /Volume1/@apps/DockerEngine/application/qbittorrent
```

## 6. 常见问题

**Q：检测报"环境缺少解压工具 xz/zstd"？**
宿主环境问题，不是包的问题。安装对应工具后重试（`apt install xz-utils zstd`）。

**Q：install 提示"未找到 docker: /VolumeN/@apps/DockerEngine/..."？**
设备未安装 DockerEngine，或其安装位置不符合 `<卷>/@apps/DockerEngine/dockerd/bin/` 约定。

**Q：想先看检测结果再决定装不装？**
先 `-c` 检测（输出全部问题），确认后再 `-i` 安装；安装过程本身也会先检测一次，发现首个问题即终止。

**Q：安装失败后目录会不会残留？**
拉取/创建失败（62%/77%）→ 解压目录已自动删除，无残留；启动/后处理失败（91%/100%）→ 保留完整安装目录，便于排查或手动重试。

**Q：支持安装 deb 包吗？**
当前版本（v1.0.0）install 仅支持 docker 应用包；deb 安装暂未支持（检测 deb 包不受影响）。
