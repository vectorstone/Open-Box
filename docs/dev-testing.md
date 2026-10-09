# 本地测试环境:QEMU 全系统 VM(主)+ Docker 冒烟(辅)

不依赖真机(R2S)就能验证新功能的两层本地设施。分层测试金字塔:

```
第 1 层  单测(mock context)              pnpm run test:server / check:config
第 2 层  面板联调                          scripts/dev-panel.sh(macOS 直跑)
第 3 层  Docker 构建产物冒烟               scripts/dev-smoke.sh   ← 本文档
第 4 层  QEMU 全系统 VM 端到端             scripts/dev-vm.sh      ← 本文档
第 5 层  真机验收(R2S)                   docs/P7-真机验收指南.md
```

原则:**大部分逻辑 bug 在 1-2 层拦住;发布前必经 3-4 层;5 层(真机)只做最终确认。**

## 为什么是这两个环境

- **QEMU VM**:跑 ImmortalWrt 官方 `armsr/armv8` 镜像 —— 与真机(rockchip/armv8)
  **用户态完全一致**(aarch64 + musl + 相同版本的 procd/uci/nft/dnsmasq/LuCI),
  内核同为 ImmortalWrt 官方内核。可以完整跑 install.sh/update.sh、防火墙、DNS
  接管、TUN 透明代理、链式代理。Mac(Apple Silicon)与目标同为 arm64,`-accel hvf`
  原生速度,无需交叉模拟。
- **Docker 冒烟**:导入同版本 ImmortalWrt rootfs,容器里完整跑一遍
  `install.sh --tarball`,验证"构建产物在 musl arm64 用户态能装、能跑"。最快,但
  共享宿主内核,**对 TUN/nft/dnsmasq 等内核级行为不做结论**。

## QEMU VM(scripts/dev-vm.sh)

### 网络拓扑(全部用户态,不动 Mac 网络)

```
Mac(hostfwd 2222→SSH / 2026→面板 / 8080→LuCI,均走 127.0.0.1)
 │
eth0  SLIRP#1 ── br-lan(默认 192.168.1.1,LAN 区,input ACCEPT)
 │                └─ veth ← netns "obclient"(模拟局域网客户端,DHCP 从 dnsmasq 取)
eth1  SLIRP#2 ── wan 区,dhcp client(互联网出口,opkg/规则集下载)
```

- Mac 经 hostfwd 进来的流量源地址落在 LAN 区,顺带验证了 `firewall.openbox_panel`
  规则(LAN→tcp/2026)本身。
- "局域网客户端"用 **netns + veth 接入 br-lan**(需 `ip-full`,setup 时已装):
  L2 语义与真实客户端一致,且可脚本化断言。

### 首次搭建

```bash
sh scripts/dev-vm.sh deps     # 检查 qemu/expect 等;缺则 brew install qemu
sh scripts/dev-vm.sh setup    # 下载镜像→扩容+2G→起 VM→provisioning→存快照 provisioned
```

setup 幂等,可中断重跑。provisioning 做的事:配 WAN(eth1 dhcp)、装
`kmod-tun ip-full parted resize2fs`、扩容 rootfs 分区、写入专用 ssh key
(`.dev-vm/id_ed25519`)。

### 日常工作流(每次新功能验证)

```bash
sh scripts/dev-vm.sh start            # headless 启动(串口日志:.dev-vm/console.log)
sh scripts/dev-vm.sh push --build     # 单测门禁 → build-release.sh arm64 → scp 到 VM
sh scripts/dev-vm.sh install          # VM 内 install.sh --tarball(验证当前工作区脚本)
```

然后浏览器打开 `http://127.0.0.1:2026` 完成首次配置/订阅导入/部署(产品行为,
不脚本化),再跑自动化验收:

```bash
sh scripts/dev-vm.sh check            # PASS/FAIL 验收电池(服务/健康/防火墙/客户端 DNS)
sh scripts/dev-vm.sh client curl -s -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204
sh scripts/dev-vm.sh stop
```

环境脏了就回快照重来:

```bash
sh scripts/dev-vm.sh reset            # 回 provisioned 快照(VM 先停)
```

### 升级链路(P7 第 8 步的本地版)

`push --build` 推新包后:

```bash
sh scripts/dev-vm.sh ssh 'sh /tmp/install.sh --tarball /tmp/open-box-linux-arm64.tar.gz'   # 装旧版(首次)
# ... 改版本号重 build,再 push ...
sh scripts/dev-vm.sh ssh 'sh /tmp/update.sh --tarball /tmp/open-box-linux-arm64.tar.gz'    # 本地包升级
```

`update.sh --tarball` 与网络通道共用全部替换/回滚/版本门禁逻辑,"已是最新版本"
的判断完全一致;订阅与密码保留可在升级后经面板或 `check` 断言。

## Docker 冒烟(scripts/dev-smoke.sh)

```bash
sh scripts/build-release.sh arm64 dist-release/
sh scripts/dev-smoke.sh           # --keep 保留失败现场容器
```

流程:导入 ImmortalWrt rootfs → `docker run --privileged /sbin/init`(procd)→
`docker cp` 进当前工作区的 `install.sh` + tarball → 容器内
`install.sh --tarball` → 断言(musl Node、sing-box、面板 running + `/api/health`、
内核服务 enabled 但未启动)。

注意:install.sh 本来就刻意不启内核,所以容器里没有 TUN 模块不影响冒烟。

## 与真机的已知差异

| 差异点 | 说明 |
|---|---|
| 内核 | armsr ≠ rockchip(板级驱动不同),但内核版本同源;Open-Box 只消费用户态设施,不受影响 |
| 网络 | SLIRP 用户态网络,吞吐量与真实 NIC 不同;性能结论一律以真机为准 |
| 存储 | VM 靠 `qemu-img resize +2G` 模拟"512MB 可用空间"约束场景,真实 flash 写入特性不同 |
| 内存 | `-m 1024` 对齐 R2S 的 1GB,内存约束可测 |
| LuCI 集成 | VM 内 LuCI 完整可用(Mac 经 127.0.0.1:8080 访问) |

发布前仍要在 R2S 上过一遍 `docs/P7-真机验收指南.md`(第 1-8 步),本地 VM 只是把
"敢不敢发布"的问题提前到本地回答。

## 备注

- `.dev-vm/` 存放镜像、ssh key、rootfs 缓存等本地资产,已 gitignore,不进仓库。
- `docs/P7-真机验收指南.md` 中的下载 URL 仍指向上游 `liandu2024` 仓库;本地验证
  一律以 `--tarball` 方式喂入本 fork 构建产物为准。
