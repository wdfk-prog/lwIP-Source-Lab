# scripts/

这里故意只保留 **5 个跨阶段通用脚本**。学习阶段自己的网络配置、抓包、Ping、运行命令都直接写在对应教程里，不再用脚本隐藏细节。

| 脚本 | 用途 |
|---|---|
| `check-env.sh` | 检查通用 Host 编译/调试工具 |
| `bootstrap-repository.sh` | 首次初始化父仓库与 `upstream/lwip` submodule |
| `sync-upstream.sh` | 后续将 submodule fast-forward 到最新 upstream `master` |
| `configure-debug.sh` | 配置 example 与 Unit Test 两套 Debug build tree |
| `build.sh` | 通用构建入口：`example`、`unit` 或 `all`；只构建，不隐式 configure |

常用命令：

```sh
# 首次
scripts/check-env.sh
scripts/bootstrap-repository.sh
scripts/configure-debug.sh
scripts/build.sh all

# 后续跟踪 master
scripts/sync-upstream.sh
scripts/configure-debug.sh
scripts/build.sh all

# 只构建 example / Unit Test
scripts/build.sh example
scripts/build.sh unit

# Unit Test 运行本身不是“构建共用逻辑”，直接执行生成物
./build/unit-tests/lwip_unittests
```

`configure-debug.sh` 的一个重要契约是：**每次 configure 都从当前 upstream `master` 的 `lwipcfg.h.example` 刷新 `lwipcfg.h`**。因此阶段专用配置统一采用：

```text
configure-debug.sh
→ 手工追加阶段 override
→ build.sh
```

不要在阶段 override 与 build 之间再次运行 configure；需要重新 configure 时，就重新应用该阶段的手工配置。

阶段专用操作不再放进 `scripts/`：

- TAP 创建/删除：教程 02 给出 `ip tuntap` / `ip link` 手工命令；
- Stage 2 静态 IPv4：教程 02 直接说明 `lwipcfg.h` 要改哪些宏；
- example 启动：教程 02 使用 `PRECONFIGURED_TAPIF=lwip0 .../example_app`；
- Ping：直接使用 `ping`；
- PCAP：直接使用 `tcpdump`；
- Wireshark：直接打开生成的 `.pcap`。

这样每个学习阶段都能看到真实系统命令和源码配置，不会被一层阶段脚本遮住。
