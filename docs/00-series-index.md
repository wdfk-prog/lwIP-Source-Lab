# lwIP Source Lab 教程索引

本系列持续跟踪官方 `lwip-tcpip/lwip` 的 `master`。绝大多数源码篇采用 **Source-driven** 主线：从当前行为的真实入口函数、注册入口或外部 API 开始，沿实际调用、数据与状态变化向下追踪。

Stage 00、15 与 38 属于 **Theory of Operation / Application Note** 型总览：先建立系统位置和完整数据流，再解释关键机制；它们不会覆盖后续源码篇“从真实入口开始”的硬约束。

## Stage 00～45

0. [Stage 00：从网线上的电信号到 lwIP——PHY、MAC、DMA 与 `netif` 的完整边界](00-ethernet-physical-layer-and-network-stack.md)
   沿物理介质、PHY、MAC、DMA/Driver 到 lwIP netif 建立 Ethernet 收发心智模型，并解释速率协商、抗干扰、冲突与 MAC 过滤。
1. [Stage 01：从 upstream `master` 到第一条可读源码链——Linux Host、构建树与源码地图](01-linux-lwip-lab.md)
   建立固定追踪 upstream master 的 Linux Host 学习仓库，理解源码、构建树、compile database 与后续源码阅读之间的关系。
2. [Stage 02：从 `main()` 到第一次 Ping——`netif`、TAP、ARP 与 ICMP 的完整源码链](02-netif-tap-first-ping.md)
   从 Unix example_app 的真实入口出发，沿 netif、TAP、ARP、IPv4、ICMP 与收发路径追踪一次真实 Ping，并用实际 PCAP 与源码逐字段互证。
3. [Stage 03：从 `low_level_input()` 到 `pbuf_free()`——`pbuf` 的数据视图、Chain 与引用计数](03-pbuf.md)
   从 TAP 接收路径里的第一次 pbuf allocation 出发，理解 payload、长度、Chain、类型与引用计数如何共同描述一个 packet。
4. [Stage 04：从 `ethernet_input()` 到 Echo Reply——Ethernet、ARP、IPv4 与 ICMP 的分层数据通路](04-ethernet-arp-ipv4-icmp.md)
   用 Stage 2 的真实四帧 Ping 抓包对照 lwIP 源码，理解 EtherType、ARP opcode、IPv4 Protocol、ICMP Type 和 pbuf 数据视图如何逐层驱动分发。
5. [Stage 05：从 `udpecho_raw_init()` 到 Echo Reply——UDP Raw API、PCB 与回调数据通路](05-udp-raw-api.md)
   从 upstream Raw UDP Echo 的真实初始化入口开始，追踪 PCB 建立、端口匹配、pbuf ownership、回调执行和 UDP Echo 回包路径。
6. [Stage 06：从 `udpecho_thread()` 到 Socket——Netconn、Mailbox 与顺序式 API](06-netconn-and-socket-api.md)
   沿 upstream Netconn UDP Echo 的 application thread 路径，理解 Netconn、netbuf、mailbox、Core Locking，以及 Socket API 如何继续封装 Netconn。
7. [Stage 07：从 `tcpecho_raw_init()` 到 `ESTABLISHED`——TCP 三次握手与 PCB 状态机](07-tcp-handshake.md)
   从 upstream Raw TCP Echo 的监听入口出发，沿 TCP 输入、监听与状态处理链追踪 passive open，理解 LISTEN PCB、连接 PCB、Sequence Number 和三次握手状态迁移。
8. [Stage 08：从 `tcp_write()` 到 ACK 清队列——TCP 数据发送、窗口与回调](08-tcp-data-path.md)
   沿 Raw TCP Echo 的真实数据路径，理解 TCP 写入如何形成待发送队列、输出如何进入待确认队列，以及 ACK 如何释放 segment、恢复发送额度并触发 callback。
9. [Stage 09：从 `tcp_slowtmr()` 到 Fast Retransmit——TCP 超时重传与重复 ACK](09-tcp-retransmission.md)
   从 Stage 8 的待确认队列继续追踪，理解 lwIP 如何用重传超时与重复 ACK 两类 loss signal 触发重传，并改变 congestion-control 状态与发送队列。
10. [Stage 10：从 `tcp_receive()` 到 `ooseq` / SACK——TCP 乱序、重组与选择确认](10-tcp-out-of-order.md)
   从 seqno 大于 rcv_nxt 的真实接收条件出发，理解 lwIP 如何保存乱序 segment、裁剪重叠、在 gap 补齐后重组连续数据，以及 SACK 如何反馈已收到的离散 range。
11. [Stage 11：从 `tcpip_init()` 到 `sys_arch`——线程、Mailbox、Timer、Semaphore 与 Core Locking](11-sys-arch.md)
   从 tcpip_init 与 tcpip_thread 主循环追踪 mailbox、timeout、semaphore、mutex 和 Core Locking，理解 Core thread 与 Unix Port 的运行边界。
12. [Stage 12：从 `pbuf_alloc()` / `tcp_new()` 到资源回收——`mem`、`memp` 与 `pbuf` 内存体系](12-mem-memp-pbuf.md)
   把 pbuf、UDP/TCP PCB、TCP segment、Netconn 与 tcpip message 放回统一资源模型，理解 variable heap、typed pools 与 packet-buffer policy。
13. [Stage 13：从 `dhcp_start()` 到 `DHCP_STATE_BOUND`——DHCPv4、ACD、Timer 与真实抓包](13-dhcpv4.md)
   从 example_app 的 DHCP 入口追踪 DORA、UDP 回调、ACD、地址绑定与租约 Timer，并用真实 13 帧 PCAP 验证状态迁移。
14. [Stage 14：从 `dns_gethostbyname()` 到 `dns_found()`——DNS Resolver、UDP PCB、Cache、Timer 与异步回调](14-dns.md)
   从 example_app 的 DNS 请求入口追踪 resolver、UDP PCB、Cache、Timer 与异步回调，并用 6 帧真实 PCAP 验证 DHCP Option 6、随机源端口、TXID、A 记录和 TTL。
15. [Stage 15：IPv4 与 IPv6——从网络层工作原理到嵌入式工程取舍](15-ipv4-ipv6-overview.md)
   从前 14 篇已经建立的 IPv4 主线出发，对照 IPv6 的地址、邻居发现、自动配置、ICMP、分片、DNS 与过渡机制，并说明 MCU、Linux 与云场景需要掌握到什么程度。
16. [Stage 16：从 MTU 到 `ip4_frag()` / `ip4_reass()`——IPv4 分片、重组、超时与内存压力](16-ipv4-fragmentation-reassembly.md)
   沿 IPv4 发送与接收源码链，理解 MTU 如何触发分片、Offset/MF/ID 如何组织片段，以及 lwIP 怎样排序、重组、超时清理并限制资源占用。
17. [Stage 17：从 `IP_ADD_MEMBERSHIP` 到 `igmp_input()`——IPv4 Multicast、IGMPv2、MAC Filter 与组成员状态机](17-igmp-ipv4-multicast.md)
   从 RTP Socket 的 IP_ADD_MEMBERSHIP 入口追踪 IGMPv2 加组、Report/Query/Leave、100 ms Timer、报告抑制与 multicast MAC 映射。
18. [Stage 18：从 `udp_sendto()` 到 `netif->output()`——Multi-netif 路由选择、Default Netif、Gateway 与 IPv6 Source Selection](18-multi-netif-routing.md)
   从 UDP/TCP 真实发送入口追踪多 netif 出口选择、默认接口、IPv4 Gateway、IPv6 ND 路由与源地址选择，并说明显式绑定接口和 route hook 的边界。
19. [Stage 19：从 `ip_chksum_pseudo()` 到 `netif->linkoutput()`——lwIP 校验和、Checksum Offload 与驱动边界](19-checksum-hardware-offload.md)
   沿 UDP/TCP 的真实收发路径解释 lwIP Internet checksum、pseudo header、per-netif checksum 控制，并明确软件校验和与 MAC/DMA 硬件卸载之间的驱动职责边界。
20. [Stage 20：从 `netif->linkoutput()` 到 `pbuf_custom`——Ethernet Driver、DMA Buffer、所有权与 Zero-copy](20-ethernet-dma-zero-copy.md)
   从 lwIP 的 linkoutput 边界进入真实 Ethernet Driver，追踪 pbuf chain、DMA buffer、custom pbuf、Cache 一致性与 zero-copy 的所有权闭环。
21. [Stage 21：从 DMA Descriptor Ring 到 `netif->input()`——ISR、Polling、TX Completion 与 Backpressure](21-ethernet-descriptor-ring-backpressure.md)
   沿真实 Ethernet Driver 边界解释 TX/RX descriptor ring、OWN 状态、ISR 与 polling、资源回收、RX starvation 和 backpressure 如何影响 lwIP。
22. [Stage 22：从 PHY Auto-Negotiation 到 `netif_set_link_up()`——Link Up/Down、MAC 速率与协议栈恢复](22-phy-link-autoneg.md)
   从 PHY 链路检测与自动协商进入 lwIP link state，区分 admin up 与 physical link，并追踪 MAC speed/duplex、DHCP、ND6 与组播报告恢复。
23. [Stage 23：从 `ethernet_input()` 到 `LWIP_HOOK_VLAN_SET`——802.1Q VLAN Tag、VID/PCP 与硬件 Offload](23-vlan-8021q-offload.md)
   从 Ethernet RX/TX 真实路径追踪 802.1Q C-Tag、TCI、VID/PCP、VLAN hook、per-PCB hint、MTU 与硬件 VLAN filtering/offload 边界。
24. [Stage 24：从 `mdns_example_init()` 到 `mdns_recv()`——mDNS、DNS-SD、Probe/Announce 与 PTR/SRV/TXT 服务发现](24-mdns-dns-sd.md)
   从 upstream mDNS example 进入 5353/组播收发，追踪 netif 加组、Probe/Announce 状态机、冲突处理、DNS-SD PTR/SRV/TXT 记录、查询匹配与多播/单播响应边界。
25. [Stage 25：从 `autoip_start()` 到 `ACD_IP_OK`——IPv4 Link-Local、169.254/16、ARP Probe/Announce、Conflict 与 DHCP Cooperation](25-autoip-ipv4-link-local.md)
   从 AutoIP 入口追踪 169.254 地址选择、AutoIP/ACD 双层状态机、ARP Probe/Announce、冲突防御、DHCP cooperation 与链路变化。
26. [Stage 26：从 `snmp_example_init()` 到 `mib2_counters`——SNMPv2c、OID Tree、GET/GETNEXT/GETBULK 与 MIB2](26-snmp-mib2.md)
   从 SNMP 示例入口追踪 UDP 161、ASN.1/PDU 解析、GET/GETNEXT/GETBULK、OID Tree、MIB2 interface/counter 映射与 RAW/NETCONN 线程边界。
27. [Stage 27：从 `lwiperf_start_tcp_server_default()` 到 TCP ACK——lwIP 吞吐量、窗口、pbuf、线程与 Driver 瓶颈定位](27-lwiperf-performance-bottleneck.md)
   从 lwiperf Raw TCP 入口追踪收发、ACK 驱动的续传、窗口与发送队列，再把 pbuf/memp、tcpip_thread、DMA ring、checksum offload 与 PHY 速率接成一条性能瓶颈证据链。
28. [Stage 28：从 `pppos_create()` 到 `ppp_input()`——PPP Core、PPPoS 串口字节流、异步 HDLC Framing 与 FCS](28-ppp-core-pppos-framing.md)
   从 upstream PPPoS example 追踪 PPP netif 创建、LCP 启动、串口 RX 跨线程输入、异步 HDLC 解帧、Protocol 分发，以及 TX 的 ACCM escaping、PFC/ACFC 与 FCS。
29. [Stage 29：从 `lcp_open()` 到 `np_up()`——LCP、PAP/CHAP、IPCP、IPv6CP 与 PPP 协商状态机](29-ppp-lcp-auth-ipcp-ipv6cp.md)
   沿 PPP phase 与 generic FSM 追踪 LCP 配置协商、PAP/CHAP 认证、Network phase、IPCP/IPv6CP 配置与网络协议启用，明确各层职责与 RUNNING 条件。
30. [Stage 30：从 `ipcp_up()` 到 `ppp_link_status_cb()`——PPP 地址、DNS、Default Route、Link Down 与 Reconnect](30-ppp-address-dns-route-reconnect.md)
   从 IPCP/IPv6CP OPENED 追踪 netif 地址、peer DNS、default netif、link up/down、PPPERR 回调、关闭与应用侧重连责任，建立 PPP 网络配置生命周期。
31. [Stage 31：从 `slipif_init()` 到 `pppos_create()`——SLIP 与 PPPoS 的串口封装、错误检测、协商与工程边界](31-slip-vs-pppos.md)
   从 lwIP 的 SLIP 与 PPPoS 两条真实串口路径对比 framing、Protocol 分发、FCS、地址配置、认证、线程桥接与错误语义，明确最小 IP framing 与完整 PPP 控制面的边界。
32. [Stage 32：从 `httpd_init()` 到 `http_sent()`——HTTPD、altcp、fsdata 与 HTTP 连接生命周期](32-httpd-altcp.md)
   从 HTTPD 真实入口追踪监听、连接状态、request parsing、fsdata 文件映射、TCP 背压与 ACK 驱动续传，理解 altcp 怎样解耦 HTTP 与传输层。
33. [Stage 33：从 `https_ex_init()` 到 `http_recv()`——altcp、mbedTLS、TLS Handshake 与 HTTPS 数据通路](33-altcp-tls-https.md)
   从 upstream HTTPS example 追踪 TLS config、TLS outer/TCP inner、mbedTLS handshake、BIO I/O 与解密后的 HTTP callback，理解 HTTPS 如何复用 Stage 32。
34. [Stage 34：从 `mqtt_example_init()` 到 `mqtt_message_received()`——MQTT CONNECT、SUBSCRIBE、PUBLISH 与回调数据通路](34-mqtt.md)
   从 upstream MQTT example 追踪 CONNECT/CONNACK、SUBSCRIBE/SUBACK、PUBLISH、request queue、ring buffer 与 incoming publish callback。
35. [Stage 35：从 `tls_config` 到 `mqtt_cyclic_timer()`——MQTT over TLS、Keep Alive、Timeout 与应用侧 Reconnect](35-mqtt-tls-reconnect-keepalive.md)
   沿 MQTT TLS 分支追踪 TLS handshake、Keep Alive、request timeout、断线清理和 connection callback，明确应用侧 reconnect/resubscribe 责任。
36. [Stage 36：从 `sntp_example_init()` 到 `sntp_process()`——SNTP、DHCP/DNS、Timer 与系统时间同步](36-sntp-system-time.md)
   从 upstream SNTP example 追踪 Server 来源、DNS/UDP request、response 校验、retry/update Timer 与系统时间 Port，并说明可信时间与 TLS certificate validity 的工程关系。
37. [Stage 37：从 `httpc_get_file_dns()` 到 Body Callback——HTTP/HTTPS Client、DNS、altcp 与下载数据通路](37-http-https-client.md)
   从 HTTP client 公共入口追踪 DNS、altcp/TCP、GET、Header/Body callback，并用 TLS allocator 把同一条 httpc 主线切换成 HTTPS，建立 REST/配置拉取/OTA 下载的网络侧基础。
38. [Stage 38：从 `lwipopts.h` 到 Port Contract——lwIP 裁剪、构建选择、OS Port 与 Network Port](38-lwip-porting-and-configuration.md)
   从产品能力反推 lwIP feature/resource 配置与源码选择，建立 `lwipopts.h`、`NO_SYS`、`sys_arch`、`netif` 和 Driver 之间的通用移植契约。
39. [Stage 39：从 `lwip_system_init()` 到 `tcpip_input()`——RT-Thread 如何把 lwIP 接进 RTOS 与 Ethernet Device](39-rtthread-lwip-port.md)
   从 RT-Thread 初始化入口追踪 Kconfig/lwipopts、sys_arch、eth_device、erx/etx 与 `tcpip_input()`，把 Stage 38 的 Port Contract 落到真实 RTOS。
40. [Stage 40：从 `socket()` 到 `lwip_socket()`——DFS fd、SAL Socket 与 lwIP Backend](40-rtthread-socket-sal-lwip.md)
   从 BSD Socket 入口追踪 DFS fd、SAL socket、NetDev/backend 选择与 `lwip_socket()`，解释 RT-Thread 怎样把 POSIX 文件描述符语义接到 lwIP Socket/Netconn。
41. [Stage 41：从 NetDev 注册到 `socket_init()`——Default NetDev、Protocol Family 与 lwIP / AT Backend 选择](41-rtthread-netdev-multi-backend.md)
   从 lwIP/AT NetDev 注册追踪 `sal_user_data`、default NetDev、primary/secondary family 匹配与 socket backend 绑定，解释同一 BSD API 如何落到不同网络实现。
42. [Stage 42：从 `rt_hw_stm32_eth_init()` 到 `tcpip_input()`——STM32H750 + RT-Thread + lwIP Ethernet Port](42-stm32h750-rtthread-lwip-ethernet-port.md)
   以 STM32H750 Art-Pi + LAN8720A 为具体硬件案例，从 RT-Thread device init 追到 HAL ETH/RMII、`eth_device`、lwIP `netif` 和 `tcpip_input()`，建立 MCU Ethernet Port 的完整落地链。
43. [Stage 43：从 `ETH_IRQHandler()` 到 `HAL_ETH_Transmit()`——STM32H7 Ethernet DMA、Descriptor、Cache 与 Zero-copy 边界](43-stm32h7-ethernet-dma-cache-zero-copy.md)
   沿同一 STM32H750 驱动的 RX/TX 数据面追踪 DMA descriptor OWN、IRQ、buffer refill、D-Cache clean/invalidate、RX pbuf copy、TX scatter-gather 与 zero-copy 生命周期边界。
44. [Stage 44：从 `phy_monitor_thread_entry()` 到 `dhcp_network_changed()`——STM32H750 PHY Link、Auto-negotiation 与 DHCP 恢复](44-stm32-phy-link-dhcp-recovery.md)
   沿 PHY monitor、BMSR latch-low、Auto-negotiation、MAC speed/duplex 重配置、`eth_device_linkchange()`、lwIP Link flag 与 DHCP reboot/discover 追踪网线插拔后的恢复链。
45. [Stage 45：从 Link Up 到 MQTT Reconnect——STM32 + RT-Thread + lwIP MCU Cloud Lifecycle](45-mcu-cloud-lifecycle.md)
   把 Link Ready、IP/DNS/Time Ready、TLS、MQTT CONNECT、Keep Alive、backoff 与 resubscribe 串成产品状态机，明确协议栈自动行为和应用层长期运行责任。

## 系列主线完成后的边界

Stage 44～45 已经把 STM32 Ethernet 的 PHY/Link 生命周期继续向上接到完整 Cloud Lifecycle。至此主线从物理链路、DMA/Driver、lwIP Core、RT-Thread Port，一直延伸到 DHCP、DNS、SNTP、TLS、MQTT 与应用侧 reconnect/resubscribe，形成完整闭环。

后续不再为了增加编号机械扩展 lwIP `src/apps` 或 RT-Thread 全量源码。新的专题只有在真实项目需要时再单独展开，例如：

```text
具体新 MCU / 新 PHY / 新 Ethernet MAC
    → 复用 Stage 38～44 的 Port / Driver / Link 方法

新的云平台 / OTA / 设备管理协议
    → 复用 Stage 34～37 + Stage 45 的 DNS / Time / TLS / Lifecycle 方法

RT-Thread Kernel / Device / DFS / SAL / NetDev 全量源码
    → 转入独立 RT-Thread Source Lab
```

当前 lwIP 系列仍只解释与网络协议、Port、真实 Ethernet 数据面和上云生命周期直接相交的 RT-Thread/STM32 路径；RT-Thread 内核对象、Device Framework、BSP Framework 与完整驱动框架留给独立 RT-Thread Source Lab。

IPv6 不再作为连续源码专题展开；Stage 15 已保留 IPv4/IPv6 的工程心智模型、标准资料与 lwIP 源码入口，项目真正需要 IPv6 时再按模块深入。

返回 [仓库 README](https://github.com/wdfk-prog/lwIP-Source-Lab#readme)。
