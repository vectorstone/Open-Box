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
# 【preinit shell 环境】procd 正常 boot 未走完:没有 ubusd、没有 br-lan。
# 手动拉起最小服务集合,让 uci/init.d/网络可用。
ubusd >/dev/null 2>&1 &
sleep 1

# WAN:eth1(SLIRP#2),dhcp client;LAN 保持默认 192.168.1.1
uci set network.wan=interface
uci set network.wan.device="eth1"
uci set network.wan.proto="dhcp"
uci commit network

# hostfwd 回包路由(SLIRP hostfwd 源地址 10.0.2.2 不在 LAN 子网,回包必须
# 有到 10.0.2.0/24 的直连路由,否则 SYN-ACK 被默认路由送去 wan 的 SLIRP 丢弃)
uci add network route 2>/dev/null || true
uci set network.@route[-1].interface="lan"
uci set network.@route[-1].target="10.0.2.0"
uci set network.@route[-1].netmask="255.255.255.0"
uci commit network

sh /etc/init.d/network start >/dev/null 2>&1 || true
sleep 5
ip route add 10.0.2.0/24 dev br-lan 2>/dev/null || true

# opt 数据盘:格式化 + 挂载(install.sh 检查 /opt 所在文件系统的可用空间,
# rootfs 只有 ~300MB 不够 512MB 预检;独立 2G 盘一次到位)。按 serial 找盘,
# 不依赖枚举顺序。
# opt 盘 = 无分区表的那块盘(blkid 无输出的整盘设备;系统盘必有 EFI 分区)
OPT_DISK=""
for d in /sys/block/vd*/device; do
  dev="/dev/$(basename "$(dirname "$d")")"
  blkid "$dev" >/dev/null 2>&1 || OPT_DISK="$dev"
done
if [ -n "$OPT_DISK" ]; then
  OD="$OPT_DISK"
  dd if=/dev/zero of="$OD" bs=1M count=1 2>/dev/null || true
  mkfs.ext4 -F "$OD" >/dev/null 2>&1 || true
  mkdir -p /opt
  mount "$OD" /opt 2>/dev/null || true
  uci -q batch <<EOB || true
add mount
set mount.@mount[-1].target=/opt
set mount.@mount[-1].fstype=ext4
set mount.@mount[-1].device=$OPT_DISK
set mount.@mount[-1].enabled=1
commit mount
EOB
fi

# 预装依赖(25.12+ 用 apk,旧版用 opkg):kmod-tun(sing-box TUN)、ip-full(netns 客户端)
# apk feed 默认镜像可能不全,先换官方源
if command -v apk >/dev/null 2>&1; then
  sed -i "s|https://mirrors.*openwrt|https://downloads.immortalwrt.org|g" /etc/apk/repositories.d/distfeeds.list 2>/dev/null || true
  apk update >/dev/null 2>&1 || true
  apk add kmod-tun ip-full >/dev/null 2>&1 || true
elif command -v opkg >/dev/null 2>&1; then
  opkg update >/dev/null 2>&1 || true
  opkg install kmod-tun ip-full >/dev/null 2>&1 || true
fi

# 写入宿主侧生成的专用 ssh key;dropbear 允许空口令 root(本地验证环境)
mkdir -p /etc/dropbear
echo "__PUBKEY__" >> /etc/dropbear/authorized_keys
chmod 600 /etc/dropbear/authorized_keys
sh /etc/init.d/dropbear start >/dev/null 2>&1 || true

echo PROVISION_DONE'

cmd_setup() {
  command -v qemu-system-aarch64 >/dev/null 2>&1 || die "未安装 qemu,先执行:brew install qemu(或 sh scripts/dev-vm.sh deps 查看全部依赖)"

  mkdir -p "$vm_dir"
  [ -f "$key" ] || ssh-keygen -q -t ed25519 -N "" -f "$key" -C "open-box-dev-vm"
  download_image

  # 满足 install.sh 的 ≥512MB 可用空间预检(MIN_FREE_KB)
  msg "扩容磁盘镜像 +2G..."
  qemu-img resize "$image" +2G >/dev/null

  msg "启动 VM(等待 provisioning)..."
  start_qemu

  # provisioning 走串口 socket + expect(见 provision_via_console):
  # 首次 boot 的 guest 还没有 10.0.2.0/24 的回包路由,hostfwd 的 SSH 根本连不上,
  # 必须先用 console 把路由加上(provision 脚本里同时做了 uci 持久化),之后
  # SSH 才可用——日常使用(push/install/check)全部走 SSH。
  # preinit 交互窗口只有几秒,expect 直连 socket 零延迟回车激活。
  msg "等待 boot、激活 preinit shell 并执行 provisioning(单会话)..."
  provision_via_console
  msg "验证 SSH 可达..."
  wait_for_ssh_empty_password
  msg "Provisioning 完成,存快照 $SNAPSHOT_DEFAULT ..."
  stop_vm_quiet
  qemu-img snapshot -c "$SNAPSHOT_DEFAULT" "$image"
  msg "setup 完成。后续:sh scripts/dev-vm.sh start && sh scripts/dev-vm.sh push --build && sh scripts/dev-vm.sh install"
}

# 单会话完成:等 preinit 提示 → 回车激活 → 逐行灌入 provisioning 脚本 → 等 PROVISION_DONE。
# 必须逐行:串口无流控,一次写超长行会溢出 guest 接收缓冲丢字节(实测 3.3KB 单行中段截断)。
# 每行 ≤200 字符,行间 150ms,确定性传输。
provision_via_console() {
  local pubkey
  pubkey="$(cat "$key.pub")"
  printf '%s\n' "$PROVISION_SCRIPT" | sed "s|__PUBKEY__|$pubkey|" > "$vm_dir/provision.sh"
  export VM_SERIAL_SOCK="$serial_sock"
  export PROVISION_FILE="$vm_dir/provision.sh"
  expect <<'EXPECT_EOF'
set timeout 1800
log_user 0
spawn nc -U $::env(VM_SERIAL_SOCK)
expect {
  -re "Please press Enter" {
    send "\r"
    expect {
      -re "root@.*#" { }
      timeout { puts "\nNO_SHELL"; exit 1 }
    }
  }
  timeout { puts "\nNO_PROMPT_BEFORE"; exit 1 }
}
send "\r"
expect -re "root@.*#"
# 先发 'sh -s' 进入脚本执行模式,再逐行灌脚本
send "sh -s\r"
after 300
set f [open $::env(PROVISION_FILE) r]
set n 0
while {[gets $f line] >= 0} {
  send "$line\r"
  incr n
  after 150
}
close $f
log_user 1
puts "\n>>> sent $n lines"
expect {
  "PROVISION_DONE" { puts "\nPROVISION_OK" }
  timeout { puts "\nPROVISION_TIMEOUT"; exit 1 }
}
sleep 1
EXPECT_EOF
}

wait_for_ssh_empty_password() {
  # provisioning 已写入专用 key(名称保留:函数在 setup 流程中承担"等 SSH 可用"职责)
  local waited=0
  while [ $waited -lt 180 ]; do
    if ssh -i "$key" -p "$SSH_PORT" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5 \
        root@127.0.0.1 "echo ok" </dev/null 2>/dev/null | grep -q ok; then
      return 0
    fi
    sleep 5; waited=$((waited + 5))
  done
  die "SSH 3 分钟不可达(路由/key/dropbear 之一异常),看 $console_log 排查。"
}

# ---------- 生命周期 ----------

start_qemu() {
  local edk2
  for edk2 in /opt/homebrew/share/qemu/edk2-aarch64-code.fd /usr/local/share/qemu/edk2-aarch64-code.fd; do
    [ -f "$edk2" ] && break
  done
  [ -f "$edk2" ] || die "找不到 edk2-aarch64-code.fd(homebrew qemu 应自带)"
  mkdir -p "$vm_dir"
  # unix socket 路径上限 104 字节,worktree 深路径放不下——用 /tmp 短路径
  monitor_sock="/tmp/open-box-vm-monitor.$UID.sock"
  serial_sock="/tmp/open-box-vm-serial.$UID.sock"
  rm -f "$monitor_sock" "$serial_sock"
  qemu-system-aarch64 \
    -M virt -accel hvf -cpu host -smp "$VM_SMP" -m "$VM_MEM" \
    -bios "$edk2" \
    -drive file="$image",if=virtio \
    $( [ -f "$vm_dir/opt.qcow2" ] && echo "-drive file=$vm_dir/opt.qcow2,if=none,id=optdisk,format=qcow2 -device virtio-blk-pci,drive=optdisk,serial=OPTDISK" ) \
    -device virtio-rng-pci \
    -netdev user,id=lan,hostfwd=tcp::${SSH_PORT}-${LAN_IP}:22,hostfwd=tcp::${PANEL_PORT}-${LAN_IP}:${PANEL_PORT},hostfwd=tcp::${LUCI_PORT}-${LAN_IP}:80 \
    -device virtio-net-pci,netdev=lan \
    -netdev user,id=wan,net=10.0.3.0/24 \
    -device virtio-net-pci,netdev=wan \
    -display none -daemonize -serial "unix:$serial_sock,server=on,wait=off" \
    -monitor "unix:$monitor_sock,server=on,wait=off"
}

# 向 qemu monitor 发送一条命令(阻塞短暂,读走回显)
monitor_cmd() {
  printf '%s\n' "$1" | nc -U "$monitor_sock" 2>/dev/null | tail -1
}


# ---------- console tee(socket→文件,供日常查看;交互时先停掉) ----------
CONSOLE_TEE_PID="$vm_dir/console-tee.pid"

start_console_tee() {
  # 常驻把串口 socket 的输出 tee 进 console.log(单向读,不占用输入方向)
  [ -f "$CONSOLE_TEE_PID" ] && kill "$(cat "$CONSOLE_TEE_PID")" 2>/dev/null || true
  python3 - "$vm_dir/serial.sock" "$console_log" <<'PYT' > /dev/null 2>&1 &
import socket, sys, time
sock_path, log_path = sys.argv[1], sys.argv[2]
while True:
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(5)
        c.connect(sock_path)
        with open(log_path, 'ab') as f:
            while True:
                data = c.recv(4096)
                if not data:
                    break
                f.write(data)
                f.flush()
    except Exception:
        pass
    time.sleep(2)
PYT
  echo $! > "$CONSOLE_TEE_PID"
}

stop_console_tee() {
  [ -f "$CONSOLE_TEE_PID" ] && kill "$(cat "$CONSOLE_TEE_PID")" 2>/dev/null || true
  rm -f "$CONSOLE_TEE_PID"
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
  start_console_tee
  msg "VM 已启动(headless)。SSH:2222 面板:2026 LuCI:8080(均走 127.0.0.1)"
  msg "串口日志:$console_log"
}

cmd_stop() {
  require_vm_running
  msg "优雅停机..."
  stop_vm_quiet
  stop_console_tee
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
    modprobe veth 2>/dev/null || true
    ip netns list | grep -q obclient || ip netns add obclient
    if ! ip link show obclient-veth >/dev/null 2>&1; then
      ip link add obclient-veth type veth peer name obclient-eth
      ip link set obclient-eth netns obclient
      ip link set obclient-veth master br-lan
      ip link set obclient-veth up
    fi
    ip netns exec obclient ip link set lo up
    ip netns exec obclient ip link set obclient-eth up
    # 静态地址:SLIRP 内置 DHCP(10.0.2.x)与 dnsmasq(192.168.1.x)同在 br-lan,
    # udhcpc 可能先收到 SLIRP 的 OFFER——本地验证用静态配置更确定
    ip netns exec obclient ip addr flush dev obclient-eth
    ip netns exec obclient ip addr add 192.168.1.50/24 dev obclient-eth
    ip netns exec obclient ip route replace default via 192.168.1.1'
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
  check "内核服务已注册(不启用=设计)" "/etc/init.d/openbox enabled || test -f /etc/init.d/openbox"
  check "面板服务已启用"           "/etc/init.d/openbox-panel enabled"
  check "面板进程在跑"             "/etc/init.d/openbox-panel status | grep -q running"
  check "面板健康检查"             "wget -q -O - http://127.0.0.1:2026/api/health | grep -o '\"ok\":true'"
  check "LuCI 菜单就位"            "test -f /usr/share/luci/menu.d/luci-app-openbox.json"
  check "LuCI ACL 就位"            "test -f /usr/share/rpcd/acl.d/luci-app-openbox.json"
  check "防火墙配置可读"           "uci -q show firewall >/dev/null"
  check "sing-box 二进制可执行"    "/opt/open-box/bin/sing-box version >/dev/null"
  check "netns 客户端可达面板"     "client_init >/dev/null; ip netns exec obclient wget -q -O - http://192.168.1.1:2026/api/health | grep -o '\"ok\":true'"
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
