#!/bin/bash
# Install the Nginx TOS Docker app with the official self-testing tool and run
# the end-to-end checks (service, port, non-root, data ownership, persistence,
# user content, user configuration).
#
# MUST be run as the TOS administrator (uid 0). No sudo needed on TOS: the admin
# account *is* root. The tool's -i mode writes under /Volume*/@apps/DockerEngine/
# and drives dockerd, so a normal user cannot run it.
#
# Usage:  bash test/install-and-verify.sh [path/to/nginxdocker.tar.gz]
set -u

PKG="${1:-$(cd "$(dirname "$0")/.." && pwd)/out/nginxdocker.tar.gz}"
APPID=nginxdocker
PORT=8081
DATA=/Volume1/DockerAppData/$APPID
DOCKER=/Volume1/@apps/DockerEngine/dockerd/bin/docker
TOOL="$(cd "$(dirname "$0")/.." && pwd)/TOSAppSelfTestingTool"

PASS=0; FAIL=0
ok()   { echo "  [ OK ] $*"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
check(){ # check <description> <command...>
  local d="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

if [ "$(id -u)" != "0" ]; then
  echo "ERROR: must run as the TOS administrator (uid 0). Current uid=$(id -u)."
  exit 1
fi
[ -s "$PKG" ] || { echo "ERROR: package not found: $PKG"; exit 1; }
[ -x "$TOOL" ] || { echo "ERROR: TOSAppSelfTestingTool not found at $TOOL"; exit 1; }

echo "== 0/6  预检：清理会占用端口/项目名的旧容器 =="
for n in $("$DOCKER" ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${APPID}(_[0-9]+)?$"); do
  echo "  移除旧容器: $n"
  "$DOCKER" rm -f "$n" >/dev/null 2>&1 || true
done
if ss -tln 2>/dev/null | grep -q ":${PORT} "; then
  echo "  !! ${PORT} 仍被占用；请先停掉占用者再重跑："
  ss -tlnp 2>/dev/null | grep ":${PORT} "
  exit 1
fi
echo "  ${PORT} 已空闲"

echo
echo "== 1/6  规范检测 + 安装 (-i) =="
"$TOOL" -i "$PKG" || { echo "安装失败，见上方逐条问题"; exit 1; }

echo
echo "== 2/6  等待 nginx 就绪 =="
ready=no
for i in $(seq 1 30); do
  if curl -fsS -m 3 "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
    ready=yes; echo "  就绪（约 ${i} 秒）"; break
  fi
  sleep 2
done
[ "$ready" = yes ] || echo "  超时：${PORT} 未响应，继续下面的诊断"

echo
echo "== 3/6  服务状态 / 非 root / 端口 =="
"$DOCKER" ps -a --filter "name=^${APPID}$" --format '  {{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}'
hstat=starting
for i in $(seq 1 20); do
  hstat=$("$DOCKER" inspect "$APPID" --format '{{.State.Health.Status}}' 2>/dev/null)
  [ "$hstat" = healthy ] && break
  sleep 3
done
[ "$hstat" = healthy ] && ok "容器 healthcheck = healthy" || bad "容器 healthcheck = ${hstat:-unknown}"
uid=$("$DOCKER" exec "$APPID" id -u 2>/dev/null)
[ "$uid" = "1000" ] && ok "容器内以 uid 1000 运行（非 root）" || bad "容器内 uid=$uid（期望 1000）"
# docker compose 会插值 ${VAR}/$VAR：若构建期的 '$$' 转义失效，容器实际拿到的
# 脚本会缺路径、变量变空串（应用照跑但行为错乱），所以查容器实际收到的 Cmd
cmd=$("$DOCKER" inspect "$APPID" --format '{{json .Config.Cmd}}' 2>/dev/null)
case "$cmd" in
  *'CONF_DIR=/config'*'exec nginx -c'*) ok "容器实际收到的 entrypoint 脚本完整（\$ 转义未被 compose 破坏）" ;;
  *) bad "容器收到的脚本不完整：$(printf '%s' "$cmd" | head -c 200)" ;;
esac
ss -tln 2>/dev/null | grep -q ":${PORT} " && ok "宿主端口 ${PORT} 已监听" || bad "宿主端口 ${PORT} 未监听"
# 只允许一个容器端口被发布；不用 nc（TOS 上不一定有，缺命令会误报为通过）；
# 也不能断言宿主 8080 空闲——TOS 自己的 nginx 就监听 8080
pub=$("$DOCKER" port "$APPID" 2>/dev/null)
npub=$(printf '%s\n' "$pub" | grep -c '^[0-9]')
if [ "$npub" = 2 ] && ! printf '%s\n' "$pub" | grep -v '^8080/tcp -> ' | grep -q '^[0-9]' \
   && printf '%s\n' "$pub" | grep -q ":${PORT}$"; then
  ok "只发布了 8080/tcp -> 宿主 ${PORT}（无多余端口）"
else
  bad "端口发布不符合预期：$(printf '%s' "$pub" | tr '\n' ' ')"
fi

echo
echo "== 4/6  数据目录与生成文件 =="
for f in config/nginx.conf config/conf.d/default.conf config/locations.conf config/README.txt www/index.html; do
  [ -s "$DATA/$f" ] && ok "已生成 $f" || bad "缺少 $f"
done
owner=$(stat -c '%u' "$DATA/config" 2>/dev/null)
[ "$owner" = "1000" ] && ok "数据目录属主已交给应用用户（uid 1000）" \
                      || bad "数据目录属主 uid=$owner（期望 1000，检查 compose 的 volumes 区块是否被注释打断）"
# 绝不允许出现字面量 /Volume* 目录（平台不展开通配符，只会把数据丢到系统分区根）；
# 只检查本应用自己的路径——同一台机器上别的应用可能踩了这个坑
[ -e "/Volume*/DockerAppData/${APPID}" ] \
  && bad "出现了字面量 /Volume*/DockerAppData/${APPID}（compose 里写了 /Volume* 通配）" \
  || ok "本应用未创建字面量 /Volume* 目录"

echo
echo "== 5/6  功能验证：用户内容 + 用户配置 + 重启持久化 =="
# the check is idempotent: the test line is only added once (re-running the
# script must not add a duplicate "location" block, which nginx rejects)
echo "hello-e2e" > "$DATA/www/e2e.txt"
grep -q 'location /e2e/' "$DATA/config/locations.conf" 2>/dev/null \
  || printf '%s\n' 'location /e2e/ { return 200 "e2e-ok\n"; }' >> "$DATA/config/locations.conf"
"$DOCKER" restart "$APPID" >/dev/null 2>&1
sleep 6
curl -fsS -m 5 "http://127.0.0.1:${PORT}/e2e.txt" 2>/dev/null | grep -q hello-e2e \
  && ok "www 目录下的文件可通过 HTTP 访问" || bad "www 目录下的文件无法访问"
"$DOCKER" exec "$APPID" nginx -t -c /config/nginx.conf >/dev/null 2>&1 \
  && ok "docker exec nginxdocker nginx -t -c /config/nginx.conf 通过" \
  || bad "配置校验命令失败"
curl -fsS -m 5 "http://127.0.0.1:${PORT}/e2e/" 2>/dev/null | grep -q e2e-ok \
  && ok "locations.conf 里的 location 生效" || bad "locations.conf 里的 location 未生效"
"$DOCKER" logs "$APPID" 2>&1 | grep -q "created $DATA/config/nginx.conf" \
  && bad "重启后重新生成了配置（不应覆盖用户文件）" \
  || ok "重启后没有覆盖已有配置文件"
curl -fsS -m 5 "http://127.0.0.1:${PORT}/e2e.txt" 2>/dev/null | grep -q hello-e2e \
  && ok "重启后用户内容仍可访问" || bad "重启后用户内容丢失"

# leave the installation exactly as a user would find it
rm -f "$DATA/www/e2e.txt"
sed -i '/location \/e2e\//d' "$DATA/config/locations.conf"

# 卸载/重装路径：Docker 应用不支持应用中心升级（官方 9.6.2），用户靠卸载重装，
# 数据必须保留。这里用 compose down（= 卸载但不删数据）+ 官方 -i 重装实测。
marker="keep-me-$$"; echo "$marker" > "$DATA/www/keep.txt"
"$DOCKER" compose -p "$APPID" down >/dev/null 2>&1
[ -d "$DATA" ] && [ -s "$DATA/www/keep.txt" ] \
  && ok "卸载（compose down）后数据目录与用户文件仍保留" \
  || bad "卸载后数据被删除"
"$TOOL" -i "$PKG" >/dev/null 2>&1 || true
for i in $(seq 1 15); do
  curl -fsS -m 3 "http://127.0.0.1:${PORT}/keep.txt" 2>/dev/null | grep -q "$marker" && break
  sleep 2
done
curl -fsS -m 5 "http://127.0.0.1:${PORT}/keep.txt" 2>/dev/null | grep -q "$marker" \
  && ok "重装后用户内容保留（重装不丢数据）" || bad "重装后用户内容丢失"
rm -f "$DATA/www/keep.txt"

echo
echo "== 6/6  结果 =="
IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -v '^172\.' | head -1)
echo "  打开：        http://${IP}:${PORT}/"
echo "  数据目录：    $DATA"
echo "  日志：        $DOCKER logs $APPID"
echo "  停止：        $DOCKER compose -p $APPID down   （数据保留）"
echo "  测试痕迹：    已自动清理（e2e.txt 与 locations.conf 里的测试行）"
echo
echo "  通过 $PASS 项，失败 $FAIL 项"
[ "$FAIL" = 0 ]
