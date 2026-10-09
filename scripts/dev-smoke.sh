#!/usr/bin/env bash
# Open-Box Docker(OrbStack)构建产物冒烟测试
#
# 用 ImmortalWrt 官方 armsr/armv8 rootfs 导入的容器,完整跑一遍当前工作区的
# install.sh --tarball,再断言二进制与面板可用——P7 验收指南第 2 步预检的容器
# 等价物 + 安装链路回归。
#
# **边界(重要)**:容器共享 OrbStack/Docker VM 的内核,不是 ImmortalWrt 内核。
# 本冒烟只回答"构建产物在 musl arm64 OpenWrt 用户态能装、能跑",对 TUN/nftables/
# dnsmasq 等内核级行为**不做任何结论**——那些归 QEMU 全系统 VM(scripts/dev-vm.sh)。
#
# 用法:
#   sh scripts/dev-smoke.sh [--keep]     --keep 保留失败现场容器不删
#   前置:dist-release/open-box-linux-arm64.tar.gz(或 OPENBOX_TARBALL 指定)

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
smoke_name="openbox-smoke"
image_tag="openbox-smoke:iwrt-25.12.2"
cache_dir="$repo_root/.dev-vm"

IWRT_VERSION="25.12.2"
IWRT_BASE="https://downloads.immortalwrt.org/releases/$IWRT_VERSION/targets/armsr/armv8"
ROOTFS_TGZ="immortalwrt-$IWRT_VERSION-armsr-armv8-generic-targz-rootfs.tar.gz"

keep=0
[ "${1:-}" = "--keep" ] && keep=1

msg() { echo "[open-box-smoke] $*"; }
die() { echo "[open-box-smoke] 错误:$*" >&2; exit 1; }
fail() { echo "[open-box-smoke] FAIL:$*" >&2; exit 1; }

cleanup() {
  if [ "$keep" -eq 1 ]; then
    msg "保留容器 $smoke_name 供排查(--keep)。"
  else
    docker rm -f "$smoke_name" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------- 前置检查 ----------

command -v docker >/dev/null 2>&1 || die "未安装 docker(推荐:brew install --cask orbstack)"
docker info >/dev/null 2>&1 || die "docker daemon 不可达,先启动 OrbStack。"

tarball="${OPENBOX_TARBALL:-$repo_root/dist-release/open-box-linux-arm64.tar.gz}"
[ -f "$tarball" ] || die "找不到构建产物 $tarball(先执行 sh scripts/build-release.sh arm64 dist-release/)"

# ---------- 导入 rootfs(幂等)----------

docker image inspect "$image_tag" >/dev/null 2>&1 || {
  msg "导入 ImmortalWrt $IWRT_VERSION rootfs(一次性,缓存于 $cache_dir)..."
  mkdir -p "$cache_dir"
  local_tgz="$cache_dir/$ROOTFS_TGZ"
  [ -f "$local_tgz" ] || curl -C - -L -o "$local_tgz" "$IWRT_BASE/$ROOTFS_TGZ" \
    || die "rootfs 下载失败:$IWRT_BASE/$ROOTFS_TGZ"
  docker import "$local_tgz" "$image_tag" >/dev/null
}

# ---------- 起容器、跑安装 ----------

docker rm -f "$smoke_name" >/dev/null 2>&1 || true
msg "启动容器(procd 作为 init)..."
docker run -d --privileged --name "$smoke_name" "$image_tag" /sbin/init >/dev/null

msg "等待 procd 就绪..."
ready=0
for _ in $(seq 1 30); do
  if docker exec "$smoke_name" sh -c "/sbin/procd_signal 2>/dev/null; ubus call system board >/dev/null 2>&1" 2>/dev/null; then
    ready=1; break
  fi
  sleep 1
done
[ "$ready" -eq 1 ] || fail "procd 60 秒内未就绪"
msg "推送构建产物与 install.sh..."
docker cp "$tarball" "$smoke_name:/tmp/open-box-linux-arm64.tar.gz"
docker cp "$repo_root/scripts/install.sh" "$smoke_name:/tmp/install.sh"

msg "容器内执行 install.sh --tarball(完整安装链路)..."
docker exec "$smoke_name" sh /tmp/install.sh --tarball /tmp/open-box-linux-arm64.tar.gz \
  || fail "install.sh 执行失败"

# ---------- 断言 ----------

msg "断言..."
docker exec "$smoke_name" sh -c 'LD_LIBRARY_PATH=/opt/open-box/node/lib /opt/open-box/node/bin/node -v' \
  | grep -q "v24" || fail "musl Node 无法运行"
docker exec "$smoke_name" sh -c '/opt/open-box/bin/sing-box version' >/dev/null \
  || fail "sing-box 无法运行"
docker exec "$smoke_name" sh -c '/etc/init.d/openbox-panel status' \
  | grep -q running || fail "面板服务未在运行"
docker exec "$smoke_name" sh -c 'curl -sf http://127.0.0.1:2026/api/health' >/dev/null \
  || fail "面板健康检查未通过"
docker exec "$smoke_name" sh -c '/etc/init.d/openbox enabled' >/dev/null \
  || fail "内核服务未注册(预期 enabled 但未启动)"

msg "全部通过:构建产物在 ImmortalWrt $IWRT_VERSION musl arm64 用户态安装+运行正常。"
msg "(内核级行为——TUN/nft/dnsmasq——不在本冒烟范围,走 scripts/dev-vm.sh)"
