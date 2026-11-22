# OTel Collector

同一镜像、两种部署形态（OTel 官方 agent / gateway 模式）。

## 文件构成

```
otel-collector/
├── base/                        # 环境无关
│   ├── config.yaml              #   gateway 管道：OTLP → 尾采 → Tempo / Prometheus
│   ├── config-agent.yaml        #   agent 管道：filelog tail stdout → Loki
│   ├── deployment-gateway.yaml  #   gateway 的 Deployment + Service
│   ├── daemonset-agent.yaml     #   agent 的 DaemonSet（hostPath + root）
│   └── kustomization.yaml       #   configMapGenerator 从上面两份配置生成 ConfigMap
├── overlays/prod/               # 单副本、尾采 10%、更大资源
└── README.md
```

配置只有一份来源：ConfigMap 不手抄，由 kustomize 在 `apply -k` 时从 `config.yaml` / `config-agent.yaml` 生成。
ConfigMap 的 key 就是文件名，所以容器参数必须严格对应 `--config=/conf/<文件名>`。

## 环境差异

只列 prod 的三项，其余**刻意不分**（分只会让行为漂移）：

| 项 | prod | 实现方式 |
|------|------|----------|
| 尾采 `healthy` 比例 | 10 | `config.yaml` 里用 `${env:TAIL_SAMPLE_PERCENT:-10}`，由 overlay 注入 env |
| gateway 副本 | 1 | tail_sampling/spanmetrics 是进程内有状态组件，多副本会打散 trace 与指标 |
| gateway 资源 | 500m/512Mi ~ 2C/1Gi | patch `resources` |

为什么采样比例走 env 而不改配置文件：ConfigMap 是 `configMapGenerator` 生成的，patch 它的 `data` 等于对一段 YAML 字符串做 JSON patch，非常难维护。

## 部署

```bash
# 前置：observability 命名空间已由 infra/base/namespaces.yaml 创建
kubectl apply -k observability/otel-collector/overlays/prod
```

也可以由 ArgoCD Application 指向 `observability/otel-collector/overlays/prod`。

配置内容一变，kustomize 会给 ConfigMap 加新的 hash 后缀，并同步改写 Pod 里的引用，
`apply -k` 时工作负载跟着滚动更新，配置自动生效，不需要手动重启。

（如果给 configMapGenerator 加上 `options.disableNameSuffixHash: true` 把名字固定，就不会触发重启，那时才需要手动执行：

```bash
kubectl -n observability rollout restart deploy/otel-collector
kubectl -n observability rollout restart ds/otel-collector-agent
```
）

## 端口

| 形态 | 端口 | 用途 |
|------|------|------|
| gateway | 4317 / 4318 | OTLP gRPC / HTTP 接收 |
| gateway | 8889 | Prometheus exporter（供抓取 collector 自身指标） |
| gateway | 13133 | health_check（`/health`） |
| agent | 13133 | health_check（`/health`） |

业务侧 `APP_OTEL_ENDPOINT` 必须是 `otel-collector.observability:4317`——业务 Pod 在 `fake-tiktok` 命名空间，跨命名空间短名不解析。

## 验证

```bash
kubectl -n observability rollout status deploy/otel-collector
kubectl -n observability rollout status ds/otel-collector-agent
kubectl -n observability get pods -o wide

# 配置合法性（部署前必跑，filelog / tail_sampling 字段随版本有差异）
otelcol-contrib validate --config=config.yaml
otelcol-contrib validate --config=config-agent.yaml

# 链路：发一次业务请求后到 Tempo 查 service.name=user-svc
# 日志：到 Loki 查 {container="user"}，应能看到带 trace_id 的 JSON 行
```

## 坑

- 用 core 镜像会直接启动失败：`filelog` receiver 与 `loki` exporter 都只在 contrib 发行版里。
- 不挂 `/var/lib/otelcol` 给 `file_storage`，Pod 重启后断点位点丢失，历史日志会重复进 Loki。
- 非 root 读不到 `/var/log/pods`（目录下全是软链），必须 `runAsUser: 0`。
- 单节点 kubeadm 集群 master 带 `NoSchedule` 污点，DaemonSet 不加容忍会漏采 master 上的 Pod。
- 只把低基数属性升为 Loki label（`level`、`container`）；`trace_id` 留在正文靠全文检索，升 label 会打爆索引。
- `tail_sampling` 的 `decision_wait` 只保证同步段到齐；转码这类分钟级长链靠头采 ParentBased 让异步段同进同出。
