# Prometheus（kube-prometheus-stack / Prometheus Operator）

三个业务服务与 worker 的指标**全部通过 OTLP 推送到 otel-collector**，Prometheus 只抓 collector 的 `:8889`。
所以这里只有一个 ServiceMonitor，指向 collector；业务侧不暴露 `/metrics`。

这样做的收益：抓取目标数固定（不随副本扩缩容变化）、不需要给每个业务端口开网络例外（Istio STRICT mTLS 时尤其省事）。
代价：**丢掉 per-pod 维度**，服务身份改用 resource 属性派生的 `service_name` 标签。

## 文件

| 文件 | 说明 |
|------|------|
| `values.yaml` | kube-prometheus-stack 基础值（server + alertmanager，grafana 关闭） |
| `values-prod.yaml` | 保留 6h / 盘 5Gi / 按量付费实验环境（长窗口 SLO 见下文「短时演示」） |
| `manifests/servicemonitor-collector.yaml` | 唯一抓取声明：otel-collector 的 `:8889` |
| `manifests/prometheusrule-slo.yaml` | 四条 SLO 的 recording rule + 告警（仅上传走燃烧率，其余阈值型） |

业务 Chart 里**没有** ServiceMonitor / PodMonitor——指标不走拉模式。

## 数据流

```
user/video/interaction/worker ──OTLP metrics──▶ otel-collector(gateway) :8889
                                                      │
                                                      ▼
                                       ServiceMonitor（本目录 manifests）
                                                      │
                                                      ▼
                                     Operator 渲染成 Prometheus 的 scrape_configs
                                                      │
                                                      ▼
                                              Prometheus ──▶ Grafana
                                                   │ 触发告警
                                                   ▼
                                       Alertmanager ──▶ null / 飞书 webhook
```

collector 侧的两个关键开关（见 [otel-collector/base/config.yaml](../otel-collector/base/config.yaml)）：

```yaml
exporters:
  prometheus:
    resource_to_telemetry_conversion:
      enabled: true    # service.name → service_name 标签，否则四个服务的同名指标会混成一条
    add_metric_suffixes: true   # 指标名统一由 exporter 翻译：counter 补 _total、有单位的补单位
```

指标命名口径（以 exporter 输出为准，业务代码只写裸名）：

| OTel 侧名字 | Prometheus 侧名字 | 说明 |
|---|---|---|
| `video_upload` / `video_transcode` / `kafka_publish` / `auth_login` | `*_total` | monotonic counter 补 `_total` |
| `calls`（spanmetrics） | `calls_total` | 同上 |
| `duration`（spanmetrics，unit=s） | `duration_seconds_bucket` | 加单位后缀，直方图再加 `_bucket` |
| `counter_flush_lag_seconds`（unit=s） | 名字不变 | 结尾已是 `seconds`，去重后不重复追加 |

**指标名是服务契约**：升级 collector 前先 diff 一次 `:8889/metrics` 的名字集合，否则名字一变，所有查询会静默变成 no data。

## 部署顺序（必须）

```bash
# 1) 先装 operator（CRD 在这一步创建）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n observability --version 65.8.1 \
  -f values.yaml -f values-prod.yaml

# 2) 再 apply 本目录的 CR（operator 没就绪时 apply 会报 no matches for kind）
kubectl apply -k observability/prometheus/manifests
```

这两步目前是手工执行；如果以后交给 ArgoCD，`manifests` 要单独一个 Application，并加
`argocd.argoproj.io/sync-wave: "1"` 排在 operator 之后。

## 抓不到指标的三个原因

| 现象 | 原因 | 修法 |
|---|---|---|
| `/targets` 里没有 collector | `serviceMonitorSelectorNilUsesHelmValues` 默认 true，只发现带 `release=<release名>` 标签的 CR | 已设为 `false`（见 values.yaml） |
| 有 target 但 `up=0` | ServiceMonitor 的 `port: prometheus` 与 Service 端口名不一致 | 端口名是**名字**匹配，不是端口号 |
| 指标名和查询对不上 | 业务代码写了后缀 + exporter 又补一次，或 collector 版本换了翻译规则 | 业务侧只写裸名，名字由 exporter 统一生成；升级前 diff 指标名集合 |
| 指标全混在一起、没有服务维度 | 没开 `resource_to_telemetry_conversion` | 已设为 `true`，标签为 `service_name` |

## 四条 SLO

| SLO | 目标 | 窗口 | 口径 | 告警方式 |
|---|---|---|---|---|
| 进程可用性（5xx/panic） | 99.5% | 1h | `1 - 5xx率`，按 `service_name` 分组。**注意**：业务响应是 HTTP 200+业务码，5xx 只剩 panic/框架级故障 | 阈值 |
| 上传成功率 | 99% | 1h | `success/(success+server_error)`，**排除 client_error** | 燃烧率 |
| 转码成功率 | 95% | 1h | `success/(success+failed)` | 阈值 |
| 计数新鲜度 | P99 < 10s | 5m 滑窗 | `histogram_quantile(0.99, ...)` | 阈值 |

窗口统一用 1h：临时测试集群 Prometheus 只保留 6h，7d/30d 窗口覆盖不满，会算出
"被标成 7d/30d 的短窗口值"。生产环境把 `ratio1h` 改回 `ratio30d` 并同步提高 retention 即可。

转码只定 95%：损坏源文件导致的 ffmpeg 失败归不到服务责任。**不做 100%**——100% 等于零错误预算。

### 短时演示：窗口里实际能看到什么

prod 只保留 **6h**（按量付费实验环境），所以能查到的原始样本最多往回 6 小时：

| 查询 | 6h 保留下实际结果 |
|---|---|
| `slo:*:ratio5m` | 正常，每分钟一个点，覆盖最近 6h |
| `slo:*:ratio1h` | 正常，覆盖最近 6h（**看板演示用这个**） |
| 燃烧率告警（1h / 5m 窗口） | 完全正常，告警链路不受影响 |
| Grafana 时间范围选 > 6h | 6h 之前是空的（不是 0），面板上表现为线段从 6h 前开始 |

结论：**看板与告警全部用 1h 以内的窗口，7d/30d 的 recording rule 已删除**（留着只会产出
无法分辨的假长窗口值）。Grafana 概览看板最后一行的「SLO 达成率（1h 演示窗口）」与
「上传 SLO 错误预算燃烧率」就是按这个口径做的。

### 为什么只有上传算燃烧率

燃烧率回答"按当前速度预算还能撑多久"，只对**连续请求型、错误预算随流量持续消耗**的核心链路有意义。本项目实验性质、无对外 SLA 赔付，只把上传这条核心用户链路纳入错误预算管理；其余三条按普通阈值告警即可：

- 进程 5xx 是低频离散事件（panic），低流量下燃烧率算不出稳定值；
- 转码是异步批处理，失败成批出现（坏源文件），比率阈值更贴切；
- 计数新鲜度是延迟 SLI，本来就是阈值型。

## 告警一览

```
燃烧率 = 实际错误率 / 允许错误率      允许错误率 = 1 - SLO 目标
```

| 告警 | 类型 | 条件 | for | 级别 |
|---|---|---|---|---|
| `SLOUploadBudgetBurning` | 燃烧率 | 1h 燃烧率 > 1 | 30m | warning |
| `SLOUploadBudgetFastBurn` | 燃烧率 | 5m 燃烧率 > 14 | 5m | critical |
| `Process5xxDetected` | 阈值 | 10m 内出现任何 5xx | 5m | warning |
| `Process5xxStorm` | 阈值 | 5m 5xx 率 > 10% | 5m | critical |
| `TranscodeFailureRateHigh` | 阈值 | 15m 失败率 > 10% | 15m | warning |
| `TranscodeFailureSpike` | 阈值 | 5m 失败率 > 30% | 5m | critical |
| `MetricsAbsent` | 失联兜底 | `calls_total` 指标消失 5m | 5m | critical |
| `SLOCounterFreshnessWarning` | 阈值 | P99 > 5s | 10m | warning |
| `SLOCounterFreshnessBreach` | 阈值 | P99 > 10s | 10m | critical |

14 的来历：5 分钟窗口占 1 小时预算的 1/12，取 14 留余量。

`MetricsAbsent` 必不可少：`rate()` 无数据时返回空，燃烧率和阈值规则都会安静得像一切正常——监控失联不能被伪装成服务健康。

## 中间件告警（`prometheusrule-middleware.yaml`）

中间件指标不进 SLO，只留"业务看着正常、数据已经错了"的慢性类告警（急性故障靠业务 5xx）：

| 告警 | 条件 | for | 级别 | 为什么值得告 |
|---|---|---|---|---|
| `MySQLConnectionsHigh` | 连接使用率 > 80% | 10m | warning | 到 100% 时新请求全部 "too many connections"，但在此之前业务指标还没有错误 |
| `RedisEvicted` | `rate(redis_evicted_keys_total[5m]) > 0` | 10m | warning | 点赞判重 SET/热度 ZSet 被驱逐后接口仍 200，计数会静默算错 |
| `KafkaConsumerLagHigh` | 单消费组 lag > 10000 | 15m | warning | 转码/计数回刷延迟被拉长，最终一致性失去意义 |
| `KafkaConsumerLagGrowing` | lag > 10000 且 15m 内仍在上涨 | 15m | critical | 消费者已停止推进，不是单纯变慢 |
| `MinioCapacityLow` | 剩余可用容量 < 20% | 10m | warning | 磁盘打满前业务全绿；打满后上传/转码全挂且**不可自愈**（要扩容+迁移） |
| `MinioNodesOffline` | 离线节点 > 0 | 5m | warning | 多副本降级运行时业务指标完全正常，这条是唯一能看见它的信号 |

指标来源与 ServiceMonitor：MySQL/Redis 由 bitnami chart 的 `metrics` 段起 sidecar（9104 / 9121）并自动生成 ServiceMonitor；Kafka 走 `kafka-exporter`（9308，SM 与 Deployment 同文件）；MinIO 走服务端 `/minio/v2/metrics/cluster`（API 端口 9000，SM 在 `manifests/servicemonitor-minio.yaml`）。全部 ClusterIP，不对外暴露。

## 网格层指标（`podmonitor-istio.yaml` + `prometheusrule-mesh.yaml`）

业务指标是 push 模型、抓取目标固定；**网格层是唯一的例外**——用 PodMonitor 按 Pod 抓
sidecar 的 `:15090/stats/prometheus`（只保留 `istio_requests_total` 等 4 个指标）。

| 层 | 指标 | 能看到什么 | 看不到什么 |
|---|---|---|---|
| 应用层（spanmetrics） | `calls_total` | HTTP 接口的 QPS/错误率/延迟，与 trace 同源 | 服务间 gRPC 调用、连接被拒、mTLS 失败、熔断 503 |
| 网格层（Envoy） | `istio_requests_total` | 全部经过 sidecar 的流量：gRPC 调用、重试、sidecar 层失败 | 业务语义（业务码、成败分类） |

**分工原则**：SLO 只用 `calls_total`（单一口径不混）；`istio_requests_total` 只用于排障与服务间
调用告警（`MeshGRPCErrorRateHigh` / `MeshUpstream503`）。两者不叠加进同一个 SLO。

代价：抓取目标数随 sidecar 数量增长（prod 按业务副本数），与"抓取目标固定"的
设计不同——这是拿到网格层数据必须付的成本，范围限定在注入 sidecar 的命名空间。

**跨命名空间发现**（已按钉住的 chart 65.8.1 模板核实）：`serviceMonitorNamespaceSelector` 渲染为 `{}` = 全命名空间，故 middleware 里的 SM 可被发现；`serviceMonitorSelectorNilUsesHelmValues: false` 让选中不依赖 release 标签。

## Alertmanager

`alertmanager.enabled: true`（kube-prometheus-stack 内置），接收器先配 `"null"`：告警能在 UI 看到但不外发。接飞书时在 `alertmanager.config.receivers` 加 `webhook_configs`。

## 验证

```bash
kubectl -n observability get prometheus,alertmanager
kubectl -n observability get servicemonitor,prometheusrule

kubectl -n observability port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
# /targets → 只有 otel-collector 一个业务相关的 target
# /rules   → slo-recording / slo-alerting
# 查询时带 service_name，例如：
#   sum by (service_name) (rate(calls_total{http_status_code=~"5.."}[5m]))   # spanmetrics 派生的 RED
#   sum by (service_name) (rate(video_upload_total{result="success"}[5m]))   # 业务埋点指标

kubectl -n observability port-forward svc/prometheus-kube-prometheus-alertmanager 9093:9093
```

collector 上直接看收到了什么：

```bash
kubectl -n observability port-forward svc/otel-collector 8889:8889
curl -s localhost:8889/metrics | grep -E 'calls_total|video_upload_total' | head
# calls_total 来自 spanmetrics（代码里已无 RED 埋点），video_upload_total 来自业务埋点
```

## 坑

- 业务侧的 `/metrics` 路由已经删了（worker 的 9091 只保留 `/health` / `/ready`），不要再对着 Pod IP 抓——会直接 404。
- 推送模式下 `instance` 标签是 collector 的地址，`pod` 维度不存在。要按 Pod 排查得回到日志（Loki 的 `container` 标签）。
- collector 当前是单副本：它挂了指标和链路一起断。要扩副本，先改成 gateway + `loadbalancing` exporter（routing_key: traceID）+ 独立采样层；直接加副本会让 Service 抓取只命中一个副本，`tail_sampling` 也会把同一 trace 打散。
- kube-prometheus-stack 的 Service/Deployment 名字带 `prometheus-kube-prometheus-` 前缀，不要按 `prometheus-server` 去找。
- `grafana.enabled: false` 是因为 Grafana 由 `observability/grafana` 单独维护。
- 默认规则集（`defaultRules`）会带来一批 K8s 层面告警，小集群有噪音；不需要可设 `defaultRules.create: false`。
