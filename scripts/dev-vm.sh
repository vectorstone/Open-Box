#!/usr/bin/env bash
# Open-Box QEMU 全系统 VM 本地验证环境
#
# 在 Mac(Apple Silicon)上用 ImmortalWrt 官方 armsr/armv8 镜像跑一台与真机
# (NanoPi R2S, rockchip/armv8)用户态完全一致的全系统 VM:aarch64 + musl +
# 相同版本的 procd/uci/nft/dnsmasq,可以完整跑 install.sh、面板、透明代理。
#
# 用法:
#   sh scripts/dev-vm.sh deps              检查依赖(qemu / ssh-keygen / expect)
#   sh scripts/dev-vm.sh setup             一次性:下载镜像 → 扩容 → 起 VM →
#                                          provisioning(配 WAN、装依赖包、写
#                                          ssh key、扩 rootfs)→ 存快照
#   sh scripts/dev-vm.sh start|stop|status 生命周期(headless,串口日志落
#                                          .dev-vm/console.log)
#   sh scripts/dev-vm.sh ssh               便捷 SSH(root@127.0.0.1:2222)
#   sh scripts/dev-vm.sh push [--build]    把构建 tarball(+install.sh)推到 VM;
#                                          --build 先跑单测门禁再出包
#   sh scripts/dev-vm.sh install           VM 内执行 install.sh --tarball
#   sh scripts/dev-vm.sh client <cmd...>   在 netns "局域网客户端"里执行命令
#                                          (无参数进入交互 shell)
#   sh scripts/dev-vm.sh check             自动化验收电池(PASS/FAIL 清单)
#   sh scripts/dev-vm.sh snapshot [name]   存快照(默认 provisioned)
#   sh scripts/dev-vm.sh reset [name]      回滚到快照(默认 provisioned)
#
# 端口映射(Mac → VM):2222→SSH、2026→面板、8080→LuCI。
# 典型工作流见 docs/dev-testing.md。

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
vm_dir="$repo_root/.dev-vm"
image="$vm_dir/image.qcow2"
key="$vm_dir/id_ed25519"
console_log="$vm_dir/console.log"

IWRT_VERSION="25.12.2"
IWRT_BASE="https://downloads.immortalwrt.org/releases/$IWRT_VERSION/targets/armsr/armv8"
IMAGE_GZ="immortalwrt-$IWRT_VERSION-armsr-armv8-generic-ext4-combined-efi.qcow2.gz"

SSH_PORT=2222
PANEL_PORT=2026
LUCI_PORT=8080
LAN_IP="192.168.1.1"
SNAPSHOT_DEFAULT="provisioned"

# VM 内存对齐 R2S 的 1GB,连内存约束都能顺带测到
VM_MEM=1024
VM_SMP=2

# ---------- 基础工具 ----------

msg()  { echo "[open-box-vm] $*"; }
die()  { echo "[open-box-vm] 错误:$*" >&2; exit 1; }

ssh_cmd() {
  ssh -i "$key" -p "$SSH_PORT" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -o LogLevel=ERROR root@127.0.0.1 "$@"
}

vm_running() {
  pgrep -f "qemu-system-aarch64.*$image" >/dev/null 2>&1
}

require_vm_running() {
  vm_running || die "VM 未运行,先执行:sh scripts/dev-vm.sh start"
}

# ---------- deps ----------

cmd_deps() {
  local ok=1
  for c in qemu-system-aarch64 qemu-img ssh-keygen expect curl; do
    if command -v "$c" >/dev/null 2>&1; then
      msg "OK:$c"
    else
      msg "缺少:$c"
      ok=0
    fi
  done
  if [ "$ok" -eq 0 ]; then
    msg "补齐方式:brew install qemu;expect/ssh-keygen/curl macOS 自带。"
    exit 1
  fi
}

# ---------- 下载与解压 ----------

download_image() {
  mkdir -p "$vm_dir"
  local gz="$vm_dir/$IMAGE_GZ"
  if [ ! -f "$image" ]; then
    msg "下载 ImmortalWrt $IWRT_VERSION armsr/armv8 镜像(断点续传)..."
    curl -C - -L -o "$gz" "$IWRT_BASE/$IMAGE_GZ" || die "镜像下载失败:$IWRT_BASE/$IMAGE_GZ"
    msg "解压..."
    gunzip -f "$gz"
    mv "$vm_dir/${IMAGE_GZ%.gz}" "$image"
  fi
}

# ---------- provisioning(一次性)----------

PROVISION_SCRIPT='set -e
# WAN:eth1(SLIRP#2),dhcp client;LAN 保持默认 192.168.1.1
uci set network.wan=interface
uci set network.wan.device="eth1"
uci set network.wan.proto="dhcp"
uci commit network

# 预装依赖:kmod-tun(sing-box TUN)、ip-full(netns 客户端)、分区扩容工具
opkg update
opkg install kmod-tun ip-full parted resize2fs

# 扩容 rootfs:第二分区(qcow2 已在宿主侧 resize +2G)
lsblk_ok=$(ls /dev/vda2 2>/dev/null || true)
if [ -n "$lsblk_ok" ]; then
  parted -s /dev/vda resizepart 2 100%
  resize2fs /dev/vda2
fi

# 写入宿主侧生成的专用 ssh key
mkdir -p /etc/dropbear
echo "__PUBKEY__" >> /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys

echo PROVISION_DONE'

cmd_setup() {
  command -v qemu-system-aarch64 >/dev/null 2>&1 || die "未安装 qemu,先执行:brew install qemu(或 sh scripts/dev-vm.sh deps 查看全部依赖)"

  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -f "$key" -C "open-box-dev-vm"
  download_image

  # 满足 install.sh 的 ≥512MB 可用空间预检(MIN_FREE_KB)
  msg "扩容磁盘镜像 +2G..."
  qemu-img resize "$image" +2G >/dev/null

  msg "启动 VM(等待 provisioning)..."
  start_qemu

  # 等 SSH 就绪(初始 dropbear 允许空口令 root 登录,用 expect 过一次交互)
  msg "等待 VM SSH 就绪..."
  wait_for_ssh_empty_password

  msg "执行 provisioning(配 WAN、装依赖包、写 ssh key、扩 rootfs)..."
  local pubkey
  pubkey="$(cat "$key.pub")"
  printf '%s\n' "$PROVISION_SCRIPT" | sed "s|__PUBKEY__|$pubkey|" > "$vm_dir/provision.sh"
  expect <<EOF
set timeout 600
spawn sh -c "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSH_PORT root@127.0.0.1 'sh -s' < $vm_dir/provision.sh"
expect {
  -re "password:" { send "\r"; exp_continue }
  "PROVISION_DONE" { }
  timeout { puts "\nPROVISION TIMEOUT"; exit 1 }
  eof { puts "\nPROVISION EOF EARLY"; exit 1 }
}
expect eof
EOF
  msg "Provisioning 完成,存快照 $SNAPSHOT_DEFAULT ..."
  stop_vm_quiet
  qemu-img snapshot -c "$SNAPSHOT_DEFAULT" "$image"
  msg "setup 完成。后续:sh scripts/dev-vm.sh start && sh scripts/dev-vm.sh push --build && sh scripts/dev-vm.sh install"
}

wait_for_ssh_empty_password() {
  expect <<EOF
set timeout 120
set done 0
for { set i 0 } { \$i < 30 } { incr i } {
  spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 -p $SSH_PORT root@127.0.0.1 true
  expect {
    -re "password:" { send "\r"; set done 1; expect eof; break }
    eof { }
    timeout { }
  }
  exec sleep 3
}
if { \$done == 0 } { puts "\nSSH NOT READY"; exit 1 }
EOF
}

# ---------- 生命周期 ----------

start_qemu() {
  local edk2
  for edk2 in /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd; do
    [ -f "$edk2" ] && break
  done
  [ -f "$edk2" ] || die "找不到 edk2-aarch64-code.fd(homebrew qemu 应自带)"
  mkdir -p "$vm_dir"
  qemu-system-aarch64 \
    -M virt -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
    -bios "$edk2" \
    -drive file="$image",if=virtio \
    -netdev user,id=lan,hostfwd=tcp::${SSH_PORT}-${LAN_IP}:22,hostfwd=tcp::${PANEL_PORT}-${LAN_IP}:${PANEL_PORT},hostfwd=tcp::${LUCI_PORT}-${LAN_IP}:80 \
    -device virtio-net-pci,netdev=lan \
    -netdev user,id=wan,net=10.0.3.0/24 \
    -device virtio-net-pci,netdev=wan \
    -display none -daemonize -serial "file:$console_log"
}

stop_vm_quiet() {
  if vm_running; then
    ssh_cmd "poweroff" >/dev/null 2>&1 || true
    for _ in $(seq 1 30); do
      vm_running || return 0
      sleep 1
    done
    pkill -f "qemu-system-aarch64.*$image" 2>/dev/null || true
  fi
}

cmd_start() {
  vm_running && { msg "VM 已在运行。"; return 0; }
  [ -f "$image" ] || die "镜像不存在,先执行:sh scripts/dev-vm.sh setup"
  start_qemu
  msg "VM 已启动(headless)。SSH:2222 面板:2026 LuCI:8080(均走 127.0.0.1)"
  msg "串口日志:$console_log"
}

cmd_stop() {
  require_vm_running
  msg "优雅停机..."
  stop_vm_quiet
  msg "VM 已停止。"
}

cmd_status() {
  if vm_running; then
    msg "VM 运行中。"
    ssh_cmd "echo guest-ok; uname -m; df -h /opt 2>/dev/null | tail -1" 2>/dev/null || msg "(SSH 暂不可达)"
  else
    msg "VM 未运行。"
  fi
}

# ---------- push / install ----------

cmd_push() {
  local do_build=0
  [ "${1:-}" = "--build" ] && do_build=1
  require_vm_running
  local tarball
  if [ "$do_build" -eq 1 ]; then
    msg "跑单测门禁(与 release.yml 对齐)..."
    (cd "$repo_root/panel" && corepack pnpm run test:server && corepack pnpm run check:config)
    msg "构建发布包 arm64..."
    (cd "$repo_root" && sh scripts/build-release.sh arm64 dist-release/)
  fi
  tarball="$repo_root/dist-release/open-box-linux-arm64.tar.gz"
  [ -f "$tarball" ] || die "找不到 $tarball,先 --build 或手动执行 sh scripts/build-release.sh arm64 dist-release/"
  msg "推送 tarball 与 install.sh 到 VM..."
  scp -i "$key" -P "$SSH_PORT" \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "$tarball" "$repo_root/scripts/install.sh" root@127.0.0.1:/tmp/ >/dev/null
  msg "推送完成:/tmp/open-box-linux-arm64.tar.gz + /tmp/install.sh"
}

cmd_install() {
  require_vm_running
  msg "VM 内执行 install.sh --tarball(当前工作区的安装脚本)..."
  ssh_cmd "sh /tmp/install.sh --tarball /tmp/open-box-linux-arm64.tar.gz"
}

# ---------- netns 客户端 ----------

client_init() {
  ssh_cmd 'set -e
    ip netns list | grep -q obclient || {
      ip netns add obclient
      ip link add obclient-veth type veth peer name obclient-eth netns obclient
      ip link set obclient-veth master br-lan
      ip link set obclient-veth up
      ip netns exec obclient ip link set obclient-eth name eth0
      ip netns exec obclient ip link set lo up
      ip netns exec obclient ip link set eth0 up
      ip netns exec obclient udhcpc -i eth0 -n -q
    }'
}

cmd_client() {
  require_vm_running
  client_init
  if [ $# -eq 0 ]; then
    ssh_cmd -t "ip netns exec obclient sh"
  else
    ssh_cmd "ip netns exec obclient $*"
  fi
}

# ---------- check(验收电池)----------

pass=0; fail=0
check() {
  local name="$1" script="$2"
  if ssh_cmd "$script" >/dev/null 2>&1; then
    echo "PASS  $name"; pass=$((pass + 1))
  else
    echo "FAIL  $name"; fail=$((fail + 1))
  fi
}

cmd_check() {
  require_vm_running
  echo "== Open-Box VM 验收电池 =="
  check "内核服务已注册"       "/etc/init.d/openbox enabled"
  check "面板服务已注册"       "/etc/init.d/openbox-panel enabled"
  check "面板进程在跑"         "/etc/init.d/openbox-panel status | grep -q running"
  check "面板健康检查"         "curl -sf http://127.0.0.1:2026/api/health"
  check "LuCI 菜单文件就位"    "test -f /usr/lib/lua/luci/controller/openbox.lua || ls /usr/libexec/rpcd/luci.openbox >/dev/null 2>&1"
  check "防火墙 openbox 规则"  "uci show firewall | grep -qi openbox"
  check "sing-box 二进制可执行" "/opt/open-box/bin/sing-box version >/dev/null"
  check "netns 客户端 DNS 解析" "client_init >/dev/null; ip netns exec obclient nslookup www.gstatic.com 127.0.0.1 2>/dev/null || ip netns exec obclient nslookup www.gstatic.com 2>/dev/null"
  echo "== 汇总:PASS=$pass FAIL=$fail =="
  [ "$fail" -eq 0 ]
}

# ---------- snapshot / reset ----------

cmd_snapshot() {
  local name="${1:-$SNAPSHOT_DEFAULT}"
  [ -f "$image" ] || die "镜像不存在,先执行:sh scripts/dev-vm.sh setup"
  qemu-img snapshot -c "$name" "$image"
  msg "快照已保存:$name"
}

cmd_reset() {
  local name="${1:-$SNAPSHOT_DEFAULT}"
  vm_running && stop_vm_quiet
  qemu-img snapshot -a "$name" "$image"
  msg "已回滚到快照:$name。执行 sh scripts/dev-vm.sh start 恢复运行。"
}

# ---------- 入口 ----------

cmd="${1:-help}"
shift || true
case "$cmd" in
  deps)     cmd_deps "$@" ;;
  setup)    cmd_setup "$@" ;;
  start)    cmd_start "$@" ;;
  stop)     cmd_stop "$@" ;;
  status)   cmd_status "$@" ;;
  ssh)      require_vm_running; exec ssh -i "$key" -p "$SSH_PORT" \
              -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
              -o LogLevel=ERROR root@127.0.0.1 ;;
  push)     cmd_push "$@" ;;
  install)  cmd_install "$@" ;;
  client)   cmd_client "$@" ;;
  check)    cmd_check "$@" ;;
  snapshot) cmd_snapshot "$@" ;;
  reset)    cmd_reset "$@" ;;
  help|-h)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)        die "未知子命令:$cmd(执行 sh scripts/dev-vm.sh help 查看用法)" ;;
esac
