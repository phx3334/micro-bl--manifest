# Kafka

用途：`video.transcode`、`video.playcount`、`video.likecount`、`video.commentcount`。

## 部署要点

- Chart：`bitnami/kafka`
- Service 名固定为 `kafka`，应用侧 `APP_KAFKA_BROKERS=kafka.middleware:9092`
- 客户端 listener 是 SSL（单向 TLS），broker 间/controller 保持明文
- `listeners.client.advertisedHost` 必须指向 `kafka.middleware.svc.cluster.local`：
  chart 默认短名 `kafka:9092` 在 `micro-bl` / `observability` 命名空间解析不到
- Demo：单节点 KRaft，无 ZooKeeper
- 允许自动创建 topic（应用启动时会创建四个 topic）
- 生产：3 broker 以上，副本数 3，开启 min.insync.replicas

```bash
helm upgrade --install kafka bitnami/kafka -n middleware \
  -f values.yaml -f values-prod.yaml
# KRaft、SSL client listener、advertised FQDN、自动建 topic 等参数都已写进 values.yaml
# （与业务侧 APP_KAFKA_BROKERS=kafka.middleware:9092 对齐）
```

Worker 的消费组：`worker-playcount`、`worker-likecount`、`worker-commentcount`、`worker-transcode`。

监控两路并存（生产标准组合）：

- **JMX exporter**（chart metrics 段：`metrics.jmx.enabled` + `metrics.serviceMonitor.enabled`）：
  抓 broker/JVM 深度指标——堆内存、GC、请求处理线程、副本同步状态。**不是独立 Deployment**：
  chart 把 exporter 以 **sidecar 容器（`jmx-exporter`，跑 jmx_prometheus_standalone.jar）直接注入
  kafka 的 StatefulSet pod**，端口名 `metrics`；自动生成 jmx-configmap + Service(`kafka-jmx-metrics`,
  `http-metrics` → targetPort `metrics`) + ServiceMonitor。部署后核对：
  `kubectl -n middleware get pod -l app.kubernetes.io/name=kafka -o jsonpath='{.items[0].spec.containers[*].name}'`
  应能看到 `jmx-exporter`。
- **kafka-exporter**（见 `observability/kafka-exporter/`）：消费组 lag + topic 流量。
  JMX 不维护 `__consumer_offsets`，**lag 只有这条路**，不可替代。

即：JMX 管"Kafka 自己病没病"，kafka-exporter 管"业务消费跟没跟上"，缺谁都不完整。
