# AGENTS.md

面向在本仓库工作的编码代理(Agent)的协作指引。

## 项目概要

Open-Box 的自维护 fork(vectorstone/Open-Box):OpenWrt 面板 + sing-box 打包,
上游为 liandu2024/Open-Box。本地验证环境为 QEMU 全系统 VM(主)+
Docker 冒烟(辅),完整说明见 `docs/dev-testing.md`。

## 新功能开发/验证流程(QEMU VM)

一次性准备(缺哪个跑哪个):

```bash
sh scripts/dev-vm.sh deps             # 检查 qemu / ssh-keygen / expect 依赖
sh scripts/dev-vm.sh setup            # 下载镜像 → provisioning → 存 provisioned 快照
```

每次功能验证的标准链路(改完代码从这里开始):

```bash
sh scripts/dev-vm.sh reset            # 回 provisioned 快照,干净基线(VM 未运行时可直接 start)
sh scripts/dev-vm.sh start            # headless 启动;SSH:2222 面板:2026 LuCI:8080(均走 127.0.0.1)
sh scripts/dev-vm.sh push --build     # 单测门禁 → build-release.sh arm64 → scp 进 VM
sh scripts/dev-vm.sh install          # VM 内 install.sh --tarball(验证当前工作区脚本)
# 需要面板手工操作时:浏览器打开 http://127.0.0.1:2026(订阅导入/部署等,产品行为不脚本化)
sh scripts/dev-vm.sh check            # 验收电池,必须 9/9 PASS
sh scripts/dev-vm.sh client curl -s -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204
sh scripts/dev-vm.sh stop             # 收尾必做,之后执行下方「残留核对」
```

规则:

- 动了 `panel/` 或 `scripts/` 就必须走 `push --build`(--build 内含与
  release.yml 对齐的单测门禁,不许跳过门禁直接灌旧包)。
- `check` 9/9 PASS 是唯一基线;任何 FAIL 先修再继续。
- 环境脏了不要手动修,`reset` 回快照重来。
- 宿主机直跑单测(不出包):`cd panel && corepack pnpm run test:server &&
  corepack pnpm run check:config`。
- 升级链路验证用 `update.sh --tarball`(见 docs/dev-testing.md「升级链路」);
  Docker 冒烟为辅:`scripts/dev-smoke.sh`。
- `.dev-vm/`(镜像/密钥/快照)不入库且已被 `.gitignore` 忽略;整目录 rsync
  到另一个 checkout 可直接使用(qcow2 无 backing file,脚本全部仓库相对路径)。

## 测试后清理(防遗留进程)

dev-vm.sh 会拉起 4 类宿主机进程,异常中断(Ctrl-C、代理会话被杀、终端关闭)
会留下孤儿进程永久空转:常驻 ~1GB 的 QEMU、无限重连循环的 console-tee
python(它永不自行退出)、tail -f、卡死的 setup 会话。以下命令均在仓库根
目录执行。

| 进程 | 识别特征(cmdline) |
|---|---|
| QEMU VM(daemonize,~1GB) | `qemu-system-aarch64 … .dev-vm/image.qcow2` |
| console tee(python,永不自行退出) | `… Python - <repo>/.dev-vm/serial.sock <repo>/.dev-vm/console.log` |
| console 跟看(人工起过才有) | `tail -f -n 0 <repo>/.dev-vm/console.log` |
| setup 会话(中断残留) | `sh scripts/dev-vm.sh setup`(及其 expect/nc 子进程) |

正常收尾:

```bash
sh scripts/dev-vm.sh stop             # 优雅关机 + 按 pidfile 杀 console-tee
```

收尾后核对(每条都应无输出;有输出 = 有残留):

```bash
pgrep -fl "qemu-system-aarch64.*$PWD/\.dev-vm/image\.qcow2"
pgrep -fl "$PWD/\.dev-vm/serial\.sock"
pgrep -fl "tail -f.*$PWD/\.dev-vm/console\.log"
pgrep -fl "dev-vm\.sh setup"
```

发现残留,一键清理(全部按本仓库绝对路径锚定,不会误伤其他 checkout/项目的 VM):

```bash
pkill -f "qemu-system-aarch64.*$PWD/\.dev-vm/image\.qcow2" 2>/dev/null || true
pkill -f "$PWD/\.dev-vm/serial\.sock $PWD/\.dev-vm/console\.log" 2>/dev/null || true
pkill -f "tail -f.*$PWD/\.dev-vm/console\.log" 2>/dev/null || true
pkill -f "dev-vm\.sh setup" 2>/dev/null || true
pkill -f "nc -U /tmp/open-box-vm-serial\.$UID\.sock" 2>/dev/null || true   # setup 的 expect 子进程
rm -f .dev-vm/console-tee.pid .dev-vm/serial.sock \
      "/tmp/open-box-vm-serial.$UID.sock" "/tmp/open-box-vm-monitor.$UID.sock"
```

纪律:

- 测试结束/会话结束必须 `stop` + 残留核对,不允许留运行中的 VM 或 tee 进程。
- 禁止只删 `.dev-vm/` 下的 pid/log/socket 文件而不杀进程——文件删了进程还在,
  就成了无法追溯的孤儿(2026-10-10 迁移 .dev-vm/ 时实测发现 4 个)。
- `pkill` 模式必须带 `$PWD` 路径锚定,禁止裸 `pkill -f qemu` 这类全局匹配。

## 记忆库

项目级记忆走 `/mb`(memory bank)。bank 按 git remote 绑定、实体存放在
Obsidian vault,同一仓库的多个 checkout 自动共享同一份,换目录/worktree
不需要迁移。
