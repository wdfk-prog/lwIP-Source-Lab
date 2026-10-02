# lwIP Source Lab

这是仓库文档站入口。项目持续跟踪官方 lwIP `master`，在 Linux Host 上把源码入口、运行时对象、协议报文和资源 ownership 放进同一条学习主线。

系列文章采用以下原则：

- 源码解读篇从当前行为的真实入口函数开始，而不是按文件顺序阅读；
- 概念在第一次真正需要时解释，并完成足够的边界与数据方向说明；
- example / Unix Port 的实现细节与 lwIP Core contract 分开描述；
- 抓包、调试等工具由当前证据需求引出，不提前做工具百科；
- Stage 0/15 这类 Theory-of-Operation 总览先建立系统位置和完整数据流，再逐层下钻；
- 复杂调用链、状态迁移和数据流优先用 Mermaid 或技术图建立运行时模型；
- 关键源码结论使用可追溯 Source Map，并链接到固定 upstream commit。

从 [教程系列索引](00-series-index.md) 开始。
