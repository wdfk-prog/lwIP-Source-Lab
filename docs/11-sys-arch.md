<meta name="referrer" content="no-referrer" />

# 教程 11：从 `tcpip_init()` 到 `sys_arch`——线程、Mailbox、Timer、Semaphore 与 Core Locking

> 摘要：从 tcpip_init 与 tcpip_thread 主循环追踪 mailbox、timeout、semaphore、mutex 和 Core Locking，理解 Core thread 与 Unix Port 的运行边界。

[TOC]

Stage 2～10 一直在使用 `tcpip_thread`，Stage 6 又出现了 application thread、mailbox 和 Core Locking。到这里才把它们单独展开，因为这些对象已经在真实调用链中反复出现。

当前 `example_app` 配置 `NO_SYS=0` 且 `LWIP_TCPIP_CORE_LOCKING=1`；`LWIP_TCPIP_CORE_LOCKING_INPUT` 沿用 Core 默认值 `0`。这三个配置共同决定本篇观察到的线程与 packet handoff 行为。[S1](#source-s1)[S2](#source-s2)

## 1. `tcpip_init()` 第一次把 lwIP Core 变成一个线程化系统

Stage 2 的启动路径已经走到：

```text
main_loop()
  -> tcpip_init(test_init, &init_sem)
```

现在进入 `tcpip_init()` 本身。当前实现按顺序做：[S3](#source-s3)

```c
lwip_init();

tcpip_init_done = initfunc;
tcpip_init_done_arg = arg;

sys_mbox_new(&tcpip_mbox, TCPIP_MBOX_SIZE);

#if LWIP_TCPIP_CORE_LOCKING
sys_mutex_new(&lock_tcpip_core);
#endif

sys_thread_new(TCPIP_THREAD_NAME, tcpip_thread, NULL,
               TCPIP_THREAD_STACKSIZE, TCPIP_THREAD_PRIO);
```

这里第一次同时出现 mailbox、mutex、thread。它们解决的是三个不同问题：

| 对象 | 解决什么问题 | 最小语义 |
| --- | --- | --- |
| thread | 谁执行 lwIP Core work | 独立执行上下文 |
| mailbox | 不同上下文怎样把 work/data 排队交给 Core | 消息队列 |
| mutex | 多线程直接进入 Core 时怎样互斥 | 同一时刻只允许一个持有者 |

不要把 mailbox 理解成“带数据的 mutex”，也不要把 mutex 理解成“只有一个元素的 mailbox”。它们的同步语义完全不同。

```mermaid
flowchart TD
    A["tcpip_init()"] --> B["lwip_init()"]
    B --> C["sys_mbox_new(tcpip_mbox)"]
    C --> D["sys_mutex_new(lock_tcpip_core)"]
    D --> E["sys_thread_new(tcpip_thread)"]
    E --> F["tcpip_thread 开始运行"]
```

## 2. `sys_*` API 是 lwIP 对 Port 的 OS contract，不是 Linux API

`src/include/lwip/sys.h` 声明了 lwIP Core 期望 Port 提供的抽象，例如：[S4](#source-s4)

```text
sys_thread_new()
sys_sem_new()
sys_arch_sem_wait()
sys_mbox_new()
sys_mbox_post()
sys_arch_mbox_fetch()
sys_mutex_new()
sys_mutex_lock()
sys_now()
```

这些名字不是 Linux pthread wrapper 的协议要求。lwIP Core 只依赖这套抽象 contract；不同 OS/Port 可以用不同底层对象实现。

当前 Unix Port 的：

```text
contrib/ports/unix/port/include/arch/sys_arch.h
contrib/ports/unix/port/sys_arch.c
```

只是这套 contract 的一种具体实现。[S5](#source-s5)[S6](#source-s6)

因此要区分：

```text
lwIP Core requirement
    sys.h 定义需要哪些抽象能力

Unix Port implementation
    用 pthread/condition/queue 等实现这些能力

example_app behavior
    当前配置怎样组合 tcpip_thread、TAP RX、Netconn
```

真实产品 Port 不必复制 Unix `sys_arch.c` 的内部结构，只需要满足 lwIP 要求的同步/时间/thread contract。

## 3. 为什么 `sys_sem_t` / `sys_mbox_t` 看起来只是 pointer

Unix `arch/sys_arch.h` 中定义：[S5](#source-s5)

```c
struct sys_sem;
typedef struct sys_sem * sys_sem_t;

struct sys_mutex;
typedef struct sys_mutex * sys_mutex_t;

struct sys_mbox;
typedef struct sys_mbox * sys_mbox_t;

struct sys_thread;
typedef struct sys_thread * sys_thread_t;
```

这是一种 **opaque handle**：Core 看到的是“某种 semaphore/mailbox/mutex handle”，但不需要知道结构体内部究竟存 pthread mutex、condition variable 还是其他 OS object。

这里的“opaque”不是加密，也不是动态类型。它只是有意隐藏 Port implementation detail，让 Core 只依赖 API contract。

## 4. `tcpip_thread` 的主循环实际上一直在消费 `tcpip_mbox`

进入 `tcpip_thread()`：线程入口先标记当前线程为 TCP/IP Core thread，取得 core lock，执行初始化 callback，然后进入永久循环。下面继续阅读 `tcpip_thread()` 的主循环：[S3](#source-s3)

```c
while (1) {                          /* MAIN Loop */
  LWIP_TCPIP_THREAD_ALIVE();
  /* wait for a message, timeouts are processed while waiting */
  tcpip_mbox_fetch(&tcpip_mbox, (void **)&msg);
  if (msg == NULL) {
    LWIP_DEBUGF(TCPIP_DEBUG, ("tcpip_thread: invalid message: NULL\n"));
    LWIP_ASSERT("tcpip_thread: invalid message", 0);
    continue;
  }
  tcpip_thread_handle_msg(msg);
}
```

这里不能只把 `tcpip_mbox_fetch()` 理解成“阻塞等 mailbox”。当 `LWIP_TIMERS=1` 时，它实际上同时等待两类事件：[S3](#source-s3)[S9](#source-s9)

1. `tcpip_mbox` 中先出现 packet/API/callback work item；
2. timeout list 中最近一个 timer 先到期。

所以 Core thread 没有 work 时不会 busy loop，但也不会因为阻塞在 mailbox 上而错过 timer。真正的等待逻辑在 `tcpip_mbox_fetch()` 内部把“最近 timeout 还剩多久”作为 mailbox 的最长阻塞时间。下面把这条之前容易被一句话带过的 timer 主线完整展开。

### 4.1 `tcpip_mbox_fetch()` 先问：最近一个 timeout 还有多久到期

`tcpip_thread()` 直接调用 `tcpip_mbox_fetch(&tcpip_mbox, ...)`；现在进入 `tcpip_mbox_fetch()`。当 `LWIP_TIMERS=1` 时，上游连续源码片段如下：[S3](#source-s3)[S9](#source-s9)

```c
static void
tcpip_mbox_fetch(sys_mbox_t *mbox, void **msg)
{
  u32_t sleeptime, res;

again:
  LWIP_ASSERT_CORE_LOCKED();

  sleeptime = sys_timeouts_sleeptime();
  if (sleeptime == SYS_TIMEOUTS_SLEEPTIME_INFINITE) {
    UNLOCK_TCPIP_CORE();
    sys_arch_mbox_fetch(mbox, msg, 0);
    LOCK_TCPIP_CORE();
    return;
  } else if (sleeptime == 0) {
    sys_check_timeouts();
    /* We try again to fetch a message from the mbox. */
    goto again;
  }

  UNLOCK_TCPIP_CORE();
  res = sys_arch_mbox_fetch(mbox, msg, sleeptime);
  LOCK_TCPIP_CORE();
  if (res == SYS_ARCH_TIMEOUT) {
    /* If a SYS_ARCH_TIMEOUT value is returned, a timeout occurred
       before a message could be fetched. */
    sys_check_timeouts();
    /* We try again to fetch a message from the mbox. */
    goto again;
  }
}
```

这段代码有三种情况。

**情况 1：当前没有任何 timeout。** `sys_timeouts_sleeptime()` 返回 `SYS_TIMEOUTS_SLEEPTIME_INFINITE`，于是：

```c
sys_arch_mbox_fetch(mbox, msg, 0);
```

当前 Unix Port 中 timeout 参数 `0` 表示无限等待，因此 Core thread 可以一直睡到 mailbox 有消息。

**情况 2：最近 timeout 已经到期。** `tcpip_mbox_fetch()` 中 `sleeptime == 0`，不再等待 mailbox，立即执行：

```text
sys_check_timeouts();
```

处理完到期 timer 后 `goto again`，重新计算下一次应等待多久。

**情况 3：最近 timeout 还没到期。** 假设还剩 137 ms：

```text
sys_timeouts_sleeptime() -> 137
```

那么可以把 `tcpip_mbox_fetch()` 的 timed wait 理解成：

```text
sys_arch_mbox_fetch(mbox, msg, 137);
```

表示“等待 mailbox，但最多只等 137 ms”。如果第 50 ms packet message 到达，mailbox 先唤醒；如果一直没有消息，137 ms 到期后返回 `SYS_ARCH_TIMEOUT`，随后调用 `sys_check_timeouts()`。

因此运行时不是“timer thread 与 tcpip_thread 两个线程竞争”，而是同一个 `tcpip_thread` 用 timed mailbox wait 同时等待两类事件：

```mermaid
flowchart TD
    A["tcpip_thread"] --> B["tcpip_mbox_fetch()"]
    B --> C["sys_timeouts_sleeptime()"]
    C --> D{"最近 timer?"}
    D -->|"没有"| E["mailbox 无限等待"]
    D -->|"已经到期"| F["sys_check_timeouts()"]
    D -->|"还有 N ms"| G["mailbox 最多等待 N ms"]
    G --> H{"谁先发生?"}
    H -->|"mailbox message"| I["返回 tcpip_thread<br/>处理 work item"]
    H -->|"等待超时"| F
    F --> B
```

### 4.2 `sys_timeouts_sleeptime()` 为什么只需要看 `next_timeout`

`sys_timeouts_sleeptime()` 没有遍历全部 timer。它只读全局链表头 `next_timeout`：[S9](#source-s9)

```c
u32_t
sys_timeouts_sleeptime(void)
{
  u32_t now;

  LWIP_ASSERT_CORE_LOCKED();

  if (next_timeout == NULL) {
    return SYS_TIMEOUTS_SLEEPTIME_INFINITE;
  }
  now = sys_now();
  if (TIME_LESS_THAN(next_timeout->time, now)) {
    return 0;
  } else {
    u32_t ret = (u32_t)(next_timeout->time - now);
    LWIP_ASSERT("invalid sleeptime", ret <= LWIP_MAX_TIMEOUT);
    return ret;
  }
}
```

原因在于 `next_timeout` 不是任意顺序的链表。所有 `struct sys_timeo` 都按**绝对到期时间从近到远排序**。因此链表头永远代表下一件最早需要发生的 timer event。

例如：

```text
next_timeout
   |
   v
+-----------+    +-----------+    +-----------+
| t=1050 ms | -> | t=1200 ms | -> | t=5000 ms | -> NULL
| handler A |    | handler B |    | handler C |
+-----------+    +-----------+    +-----------+
```

如果当前 `sys_now() = 1000 ms`，Core thread 最多只需要等 50 ms；1050 ms 的节点没处理完之前，后面的 1200/5000 ms 不可能更早到期。

### 4.3 timer 为什么天然按到期时间排序：`sys_timeout_abs()` 的插入逻辑

`sys_timeout()` 先计算：

```text
absolute due time = sys_now() + msecs
```

随后调用 `sys_timeout_abs()`。进入 `sys_timeout_abs()` 后，新节点从 `MEMP_SYS_TIMEOUT` 分配并填写 `handler`、`arg`、`time`；然后按 `time` 插入 `next_timeout` 链表。[S9](#source-s9)

```c
timeout->next = NULL;
timeout->h = handler;
timeout->arg = arg;
timeout->time = abs_time;

if (next_timeout == NULL) {
  next_timeout = timeout;
  return;
}
if (TIME_LESS_THAN(timeout->time, next_timeout->time)) {
  timeout->next = next_timeout;
  next_timeout = timeout;
} else {
  for (t = next_timeout; t != NULL; t = t->next) {
    if ((t->next == NULL) || TIME_LESS_THAN(timeout->time, t->next->time)) {
      timeout->next = t->next;
      t->next = timeout;
      break;
    }
  }
}
```

所以 `sys_timeout()` 注册一个 timer 的本质不是创建 OS timer object，而是把一个：

```text
{ absolute_due_time, handler, arg }
```

节点插进 lwIP 自己管理的有序链表。

### 4.4 `sys_check_timeouts()` 到底怎样执行 handler

当 `tcpip_mbox_fetch()` 判断 timer 已到期，直接进入 `sys_check_timeouts()`。下面是主循环的上游连续源码片段：[S9](#source-s9)

```c
u32_t
sys_check_timeouts(void)
{
  u32_t now;

  LWIP_ASSERT_CORE_LOCKED();

  /* Process only timers expired at the start of the function. */
  now = sys_now();

  do {
    struct sys_timeo *tmptimeout;
    sys_timeout_handler handler;
    void *arg;

    PBUF_CHECK_FREE_OOSEQ();

    tmptimeout = next_timeout;
    if (tmptimeout == NULL) {
      return SYS_TIMEOUTS_SLEEPTIME_INFINITE;
    }

    if (TIME_LESS_THAN(now, tmptimeout->time)) {
      u32_t ret = (u32_t)(tmptimeout->time - now);
      LWIP_ASSERT("invalid sleeptime", ret <= LWIP_MAX_TIMEOUT);
      return ret;
    }

    /* Timeout has expired */
    next_timeout = tmptimeout->next;
    handler = tmptimeout->h;
    arg = tmptimeout->arg;
    current_timeout_due_time = tmptimeout->time;
    memp_free(MEMP_SYS_TIMEOUT, tmptimeout);
    if (handler != NULL) {
      handler(arg);
    }
    LWIP_TCPIP_THREAD_ALIVE();

    /* Repeat until all expired timers have been called */
  } while (1);
}
```

真实执行顺序是：

```text
读取一次 now = sys_now()
    -> 看 next_timeout
    -> 没有节点：返回 INFINITE
    -> 头节点还没到期：返回剩余毫秒数
    -> 头节点已经到期：
         从链表摘下
         保存 handler/arg
         free MEMP_SYS_TIMEOUT node
         handler(arg)
         再检查下一项
```

例如：

```text
now = 1300 ms

1050 ms handler A -> 已过期 -> 调用
1200 ms handler B -> 已过期 -> 调用
5000 ms handler C -> 未到期 -> 返回 3700 ms
```

返回的 3700 ms 随后又会成为下一轮 `tcpip_mbox_fetch()` 的 mailbox 最大等待时间。

### 4.5 为什么 `sys_check_timeouts()` 开头只读取一次 `sys_now()`

源码注释明确写着：

```c
/* Process only timers expired at the start of the function. */
now = sys_now();
```

因此本轮只处理“函数进入这一刻已经到期”的节点。假设 handler A 自己执行了 100 ms，并使另一个 timer 在 handler 执行期间刚刚到期，当前 `now` 不会在循环中刷新成新时间；该 timer 可以留到下一轮 `tcpip_mbox_fetch()` / `sys_check_timeouts()` 再处理。[S9](#source-s9)

这个细节避免 `sys_check_timeouts()` 因 handler 执行时间较长而无限追赶“刚刚又到期”的 timer，同时也说明 lwIP software timer 不是硬实时中断：callback 的实际执行时间还受 Core thread 当前处理工作和前一个 handler 执行时间影响。

### 4.6 `dhcp_fine_tmr()` 这种“每 500 ms”周期任务，本质仍是反复注册 one-shot timeout

`sys_timeouts_init()` 会把 DHCP、ARP、DNS、ND6 等 `lwip_cyclic_timers[]` 项通过 `sys_timeout()` 放入同一 timeout list。[S9](#source-s9)

到期时，真正首先被调用的是通用 wrapper：

```c
void
lwip_cyclic_timer(void *arg)
{
  u32_t now;
  u32_t next_timeout_time;
  const struct lwip_cyclic_timer *cyclic = (const struct lwip_cyclic_timer *)arg;

  cyclic->handler();

  now = sys_now();
  next_timeout_time = (u32_t)(current_timeout_due_time + cyclic->interval_ms);
```

`cyclic->handler()` 可能就是：

```text
dhcp_fine_tmr()
dhcp_coarse_tmr()
etharp_tmr()
dns_tmr()
nd6_tmr()
...
```

handler 返回后，`lwip_cyclic_timer()` 再调用 `sys_timeout_abs()` 注册下一次 due time。[S9](#source-s9)

所以“每 500 ms 调 `dhcp_fine_tmr()`”的实现模型不是：

```text
独立 timer thread 每 500 ms sleep/wake
```

而是：

```text
one-shot sys_timeo 到期
    -> tcpip_mbox_fetch() timed wait 超时
    -> sys_check_timeouts()
    -> lwip_cyclic_timer()
    -> dhcp_fine_tmr()
    -> 再把下一次 one-shot due time 插回有序 timeout list
```

TCP timer 是这个体系里的特殊项：`sys_timeouts_init()` 刻意跳过 `lwip_cyclic_timers[0]` 的 TCP timer，由 `tcp_timer_needed()` 根据 active/TIME-WAIT PCB 按需启动；Stage 9 已经展开该特殊路径。[S9](#source-s9)

### 4.7 Mailbox 和 Timer 最终在同一个 `tcpip_thread` 串行汇合

到这里可以把本篇最容易混淆的“线程 + IPC + timer”关系放到一张图里：

```mermaid
flowchart TD
    A["TAP RX / API / callback producer"] --> B["tcpip_mbox"]
    C["有序 next_timeout 链表"] --> D["sys_timeouts_sleeptime()"]
    B --> E["tcpip_mbox_fetch()"]
    D --> E
    E --> F{"先发生什么?"}
    F -->|"mailbox message"| G["tcpip_thread_handle_msg()"]
    F -->|"timer 到期"| H["sys_check_timeouts()"]
    H --> I["handler(arg)"]
    G --> J["回到 tcpip_thread 主循环"]
    I --> J
```

因此当前 OS mode 下不存在“一个 timer thread 与一个 packet thread 同时修改 lwIP Core”的默认模型。packet work、API/callback work 与大量 protocol timer handler 最终都在 `tcpip_thread` 的 Core execution context 中串行推进；Core Locking 允许特定外部线程在满足约束时同步进入 Core，但那是另一条受锁保护的入口。[S3](#source-s3)[S9](#source-s9)

回到 `tcpip_thread()`：当 `tcpip_mbox_fetch()` 最终因为 mailbox message 返回，主循环才继续调用 `tcpip_thread_handle_msg()`。`tcpip_thread_handle_msg()` 根据 `msg->type` 区分 input packet、callback、timeout request 等 work item。[S3](#source-s3)

因此 mailbox 里放的不是固定一种 packet pointer，而是 `struct tcpip_msg` 描述的不同 work item。

## 5. `struct tcpip_msg` 是跨线程 work item

Stage 2 RX 路径里曾看到：

```text
tcpip_input(p, netif)
```

这一层并没有直接调用 `ethernet_input()`。当前 `LWIP_TCPIP_CORE_LOCKING_INPUT=0` 时，`tcpip_inpkt()` 会：[S3](#source-s3)[S2](#source-s2)

1. 从 `MEMP_TCPIP_MSG_INPKT` 分配一个 `tcpip_msg`；
2. 填入 `p`、`netif` 和 `input_fn`；
3. 标记类型为 `TCPIP_MSG_INPKT`；
4. `sys_mbox_trypost(&tcpip_mbox, msg)`。

```mermaid
sequenceDiagram
    participant R as TAP RX context
    participant M as tcpip_mbox
    participant T as tcpip_thread
    participant E as ethernet_input()

    R->>R: tcpip_input(p, netif)
    R->>M: TCPIP_MSG_INPKT {p, netif, ethernet_input}
    T->>M: sys_arch_mbox_fetch()
    M-->>T: msg
    T->>E: input_fn(p, netif)
```

这就是 RX 的 **handoff**：接包上下文负责把 work 交进 mailbox；真正的 Ethernet/IP/TCP/UDP Core processing 在 `tcpip_thread` 中继续。

## 6. 为什么当前 RX 仍走 mailbox，即使 `LWIP_TCPIP_CORE_LOCKING=1`

这是一个最容易混淆的配置组合。

`LWIP_TCPIP_CORE_LOCKING=1` 表示某些 non-Core threads 可以先取得 `lock_tcpip_core`，然后同步调用允许的 lwIP Core API。[S1](#source-s1)[S3](#source-s3)

但 packet input 是否直接用 core lock，是另一个选项：

```c
LWIP_TCPIP_CORE_LOCKING_INPUT
```

Core 默认是 `0`。[S2](#source-s2)

因此当前配置可以同时成立：

```text
Netconn/API control path
    可能通过 Core Locking 直接同步执行

RX packet input
    仍打包成 TCPIP_MSG_INPKT
    经过 tcpip_mbox
    由 tcpip_thread 调用 ethernet_input()
```

“用了 Core Locking”并不推出“mailbox 不再存在”。两者可以服务不同入口。

## 7. Core Locking 到底锁的是什么

`LOCK_TCPIP_CORE()` / `UNLOCK_TCPIP_CORE()` 保护的是 lwIP Core shared state，让允许的外部线程在持锁期间安全访问 Core API。[S3](#source-s3)[S5](#source-s5)

当前 Unix Port 将这组宏映射到 `sys_lock_tcpip_core()` / `sys_unlock_tcpip_core()`，底层使用 Port 的 mutex implementation。[S5](#source-s5)[S6](#source-s6)

它与普通 application mutex 的区别不在“mutex 类型更特殊”，而在**被保护的 invariant**：

> 持有 core lock 的上下文被允许访问本应串行化的 lwIP Core state。

所以不能随意拿其他 mutex 代替，也不能只看到某个 API 内部没有 mailbox 就认为它天然 thread-safe。

## 8. Mailbox、Semaphore、Mutex 为什么要同时存在

### 8.1 Mailbox：传 work/data

典型用途：

```text
producer thread/context
  -> post message
  -> consumer later fetch
```

它既有同步意义，也有消息内容。

### 8.2 Semaphore：等待一个事件完成

Stage 2 `main_loop()` 在调用 `tcpip_init(test_init, &init_sem)` 后执行：

```text
sys_sem_wait(&init_sem)
```

而 `test_init()` 在 `tcpip_thread` context 完成 netif/app 初始化后 signal 这个 semaphore。[S7](#source-s7)

因此 semaphore 这里表达的是：

```text
main thread 等待“初始化完成”事件
```

不需要传一个 packet queue。

### 8.3 Mutex：临界区互斥

mutex 解决：

```text
多个线程都可能直接触碰同一份共享状态
```

同一时刻只允许一个进入关键区。

三者最小对比：

| primitive | 是否携带消息 | 是否通常有 owner | 典型用途 |
| --- | --- | --- | --- |
| mailbox | 是 | 否 | 异步 work/data handoff |
| semaphore | 否，主要是计数/事件 | 通常不强调 mutex 式 owner | wait/signal 同步 |
| mutex | 否 | 是 | 共享状态临界区 |

## 9. `SYS_ARCH_PROTECT` 又是另一层保护

`SYS_ARCH_PROTECT` / `SYS_ARCH_UNPROTECT` 面向的是更小粒度的 lightweight critical region，例如内存/统计等需要短时间原子保护的路径；它不是 `lock_tcpip_core` 的别名。[S4](#source-s4)[S6](#source-s6)

两者保护的 scope 不同：

```text
Core lock
  保护 lwIP Core 访问序列化

SYS_ARCH_PROTECT
  保护特定短临界区的并发原子性
```

一个 Port 可以用不同底层 primitive 实现它们。不能因为两者最终都可能碰 mutex/critical-section API，就把语义混在一起。

## 10. Unix Port 如何实现这些抽象

当前 Unix `sys_arch.c` 使用 pthread 体系实现 thread、mailbox、semaphore、mutex 等对象。[S6](#source-s6)

重要的是 API 语义，不是背结构体字段：

```text
sys_thread_new()
    -> 创建 Host thread

sys_mbox_new/post/fetch()
    -> 建立 bounded message queue + 等待/唤醒

sys_sem_new / sys_arch_sem_wait / sys_sem_signal
    -> event/count synchronization

sys_mutex_new / lock / unlock
    -> mutual exclusion
```

Unix Port 适合 Host 学习，因为这些对象在普通进程里可观察；它并不意味着 embedded Port 也必须使用 pthread。

## 11. 把 Stage 2 与 Stage 6 的线程路径放到同一张图

```mermaid
flowchart TD
    subgraph RX["Packet RX path"]
      A["TAP RX context"] --> B["tcpip_input()"]
      B --> C["TCPIP_MSG_INPKT"]
      C --> D["tcpip_mbox"]
      D --> E["tcpip_thread"]
      E --> F["ethernet_input / ip4_input / TCP/UDP"]
    end

    subgraph API["Sequential API path"]
      G["application thread"] --> H["Netconn call"]
      H --> I["Core Locking / API implementation"]
      I --> F
      F --> J["recvmbox / result"]
      J --> G
    end
```

这张图不是说“所有 Netconn call 永远都不经过任何 mailbox”。Netconn 自己仍有 receive mailbox、completion synchronization 等对象；这里只表达当前 `LWIP_TCPIP_CORE_LOCKING=1` 下，Core API execution 与 RX input handoff 可以采用不同串行化机制。[S1](#source-s1)[S3](#source-s3)[S8](#source-s8)

## 12. Core、Port、example 三层最终边界

到这里可以明确哪些是 lwIP 的通用设计，哪些只是当前 Host 实验实现：

| 层次 | 本篇事实 |
| --- | --- |
| lwIP Core contract | `sys.h` 定义 thread/sem/mbox/mutex/time 抽象；OS mode 有 `tcpip_thread`/Core synchronization model |
| Unix Port | `sys_arch.c` 用 pthread 等 Host primitives 实现抽象 |
| current example config | `NO_SYS=0`、Core Locking 开启、packet input locking 关闭，因此 RX 仍走 `tcpip_mbox` |
| production implication | 目标平台需要满足同等 contract，但具体线程、ISR bottom-half、queue/mutex primitive 可完全不同 |

Stage 12 会继续利用这条分层思路，把“内存不足”也拆成 `mem` heap、`memp` typed pools 和 `pbuf` allocation policy，而不是笼统看成同一个 allocator。

## 资料来源

<a id="source-s1"></a>
### [S1] current example threading 配置
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/examples/example_app/lwipopts.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/example_app/lwipopts.h)
- 使用位置：`NO_SYS=0`、`LWIP_TCPIP_CORE_LOCKING=1`
- 支撑内容：限定当前 article 的 example configuration

<a id="source-s2"></a>
### [S2] Core threading option defaults
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/include/lwip/opt.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/opt.h)
- 使用位置：`LWIP_TCPIP_CORE_LOCKING_INPUT=0`
- 支撑内容：packet input 是否通过 mailbox 或直接 core lock 的配置边界

<a id="source-s3"></a>
### [S3] `tcpip_thread`、`tcpip_mbox` 与 Core Locking
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/api/tcpip.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/api/tcpip.c)
- 使用位置：`tcpip_init()`、`tcpip_thread()`、`tcpip_inpkt()`、message dispatch
- 支撑内容：OS mode Core thread 创建、input message handoff、callback/message processing

<a id="source-s4"></a>
### [S4] lwIP OS abstraction contract
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/include/lwip/sys.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/sys.h)
- 使用位置：thread/semaphore/mailbox/mutex/`SYS_ARCH_PROTECT`
- 支撑内容：lwIP Core 对 OS Port 的抽象 API 需求

<a id="source-s5"></a>
### [S5] Unix `sys_arch` type mapping
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/ports/unix/port/include/arch/sys_arch.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/ports/unix/port/include/arch/sys_arch.h)
- 使用位置：opaque handles 与 Core Locking macros
- 支撑内容：Unix Port 如何向 Core 暴露 `sys_*` handle 类型

<a id="source-s6"></a>
### [S6] Unix `sys_arch` implementation
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/ports/unix/port/sys_arch.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/ports/unix/port/sys_arch.c)
- 使用位置：thread、mailbox、semaphore、mutex 与 lightweight protection 的 Host implementation
- 支撑内容：当前 Unix Port 的具体 synchronization primitives

<a id="source-s7"></a>
### [S7] example startup synchronization
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/examples/example_app/test.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/example_app/test.c)
- 使用位置：`main_loop()` 的 init semaphore 与 `test_init()` signal
- 支撑内容：semaphore 在当前 startup path 中解决的实际等待关系

<a id="source-s8"></a>
### [S8] Netconn implementation
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/api/api_lib.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/api/api_lib.c)、[`src/api/api_msg.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/api/api_msg.c)
- 使用位置：application thread、Core API execution 与 receive mailbox
- 支撑内容：Stage 6 的 sequential API 如何和本篇 `tcpip_thread`/Core Locking 模型衔接

<a id="source-s9"></a>
### [S9] lwIP software timeout scheduler
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/timeouts.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/timeouts.c)
- 使用位置：`sys_timeout_abs()`、`sys_timeouts_sleeptime()`、`sys_check_timeouts()`、`lwip_cyclic_timer()` 与 `sys_timeouts_init()`
- 支撑内容：证明 timeout 节点按绝对到期时间排序、`tcpip_mbox_fetch()` 如何计算等待时长、到期 handler 如何执行，以及 cyclic timer 如何重新注册下一次 one-shot timeout
