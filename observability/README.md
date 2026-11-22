# Observability

目标链路：

```
user/video/interaction/worker --OTLP gRPC--> otel-collector (gateway)
                                                 |-- traces --> Tempo --> Grafana
                                                 |-- metrics --> Prometheus --> Grafana
业务 Pod stdout (JSON) --otel-collector (agent, DaemonSet)--> Loki --> Grafana
```

## 组件

| 组件 | 用途 | 状态 |
|------|------|------|
| otel-collector（gateway） | Deployment，接收 OTLP，按信号分流 | 配置见 base/config.yaml |
| otel-collector（agent） | DaemonSet，filelog 采集容器 stdout → Loki | 配置见 base/config-agent.yaml |
| prometheus | kube-prometheus-stack（Operator）：ServiceMonitor/PodMonitor 抓取，SLO 与燃烧率告警 | Helm + CRD，见 prometheus/ |
| tempo | Trace 存储（单机 + MinIO S3 后端） | kustomize base/overlays，见 tempo/ |
| loki | 日志存储（单片模式，agent push） | kustomize base/overlays，见 loki/ |
| grafana | 看板：数据源与 dashboard 全部 provisioning（IaC），prod 走 NodePort 30300（给人看的入口）。两个看板：业务概览 + 中间件 | kustomize base/overlays，见 grafana/ |
| kafka-exporter | Kafka broker + worker 四个消费组 lag（供 KEDA / 告警）。**部署在 observability 命名空间**（middleware 不注入 sidecar 后无需同空间，连 kafka.middleware:9092 走应用层单向 TLS） | kustomize，见 kafka-exporter/ |

中间件指标：MySQL（mysqld_exporter 9104）、Redis（redis_exporter 9121）、Kafka（两路并存：chart 内置 JMX exporter `http-metrics` 端口抓 broker/JVM 深度指标 + kafka-exporter 9308 抓消费组 lag）、MinIO（服务端 `/minio/v2/metrics/cluster`，与 API 共用 9000）均以 ClusterIP 暴露，由 ServiceMonitor 抓取；MySQL/Redis/Kafka 的 ServiceMonitor 随 chart 生成在 middleware，其余两个在 `prometheus/manifests/`。

## 业务侧约定

- 三个 HTTP 服务与 worker（:9091，仅探针）都暴露 `/health`（liveness）与 `/ready`（readiness）；指标不落 `/metrics`，四个进程统一 OTLP 推送到 collector，由 Prometheus 抓 collector 的 `:8889`。
- Trace 通过 OTLP gRPC 上报，服务名由进程内 `OTEL_SERVICE_NAME` 决定。
- 日志输出 stdout JSON，由 otel-collector 的 filelog receiver 采集后写入 Loki（业务代码不做日志上报）。
- Grafana 数据源 uid：`prometheus`、`tempo`、`loki`，保持固定便于看板复用。

## 初始 Collector

同一个镜像、两种部署形态（OTel 官方 agent / gateway 模式）：

| 形态 | 工作负载 | 配置 | 端口 | 职责 |
|------|----------|------|------|------|
| gateway | Deployment + Service `otel-collector` | [base/config.yaml](otel-collector/base/config.yaml) | 4317/4318/8889/13133 | 接收 OTLP，分流到 Tempo；prometheus exporter 供抓取 |
| agent | DaemonSet `otel-collector-agent` | [base/config-agent.yaml](otel-collector/base/config-agent.yaml) | 13133 | tail `/var/log/pods`，解析 zap JSON 后写 Loki |

部署：`kubectl apply -k observability/otel-collector/overlays/prod`。kustomize 用 `configMapGenerator` 从配置文件现场生成 ConfigMap，配置只有一份来源。

agent 形态的三条硬约束（详见 [otel-collector/README.md](otel-collector/README.md)）：contrib 镜像、hostPath `/var/log/pods` 且以 root 运行、hostPath `/var/lib/otelcol` 做断点续采。
