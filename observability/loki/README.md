# Loki

日志存储，单片模式（monolithic），只保留 prod overlay。

## 目录

```
loki/
├── base/
│   ├── loki.yaml          # 配置：文件系统后端 + tsdb 索引；保留期用 ${LOKI_RETENTION} 占位
│   ├── deployment.yaml    # Deployment + Service + 数据 PVC（10Gi）
│   └── kustomization.yaml # configMapGenerator 从 loki.yaml 生成 ConfigMap
├── overlays/
│   └── prod/              # 保留 14d，大资源
└── README.md
```

## 数据流

```
collector agent（DaemonSet）──HTTP push──▶ loki:3100/loki/api/v1/push ──▶ PVC（chunks + index）
```

agent 的 push 端点在 `otel-collector/base/config-agent.yaml`，同命名空间直连 Service，无需额外接线。

## 关键设计

- **单片三件套**：`replication_factor: 1` + `ring.kvstore: inmemory` + 文件系统后端。三者是一个整体，扩到多副本必须一起改（ring 换 memberlist，存储换 S3）。
- **保留期只声明不生效**：`limits_config.retention_period` 只是声明，真正删数据靠 `compactor.retention_enabled: true`；compactor 没跑数据就一直涨。
- **没有 MinIO**：tempo 用了 MinIO，loki 用本地 PVC——日志可再生（collector 重启后从 `start_at` 重新 tail 或丢少量尾部），trace 不可再生，值得更好的存储。
- **迁云盘**：只需给 PVC 改 `storageClassName`（或换默认 SC），配置文件不动。

## 部署

```bash
kubectl apply -k observability/loki/overlays/prod
```

## 端口

| 端口 | 用途 |
|---|---|
| 3100 | HTTP：agent push `/loki/api/v1/push`、查询 `/loki/api/v1/query_range`、`/ready` 探针 |

## 验证

```bash
kubectl -n observability rollout status deploy/loki
kubectl -n observability port-forward svc/loki 3100:3100
curl -s localhost:3100/ready
# agent 推完一条日志后：
curl -sG localhost:3100/loki/api/v1/query_range --data-urlencode 'query={container="worker"}' --data-urlencode 'limit=5'
```

## 坑

- `ingestion_rate_mb: 16` 是全局限速，超出返回 429（agent 侧丢日志）。日志洪峰要调大或配多租户限额。
- 标签只升 `level,container`（见 agent 配置的 `loki.attribute.labels`）；往 label 里塞 trace_id/user_id 会打爆 index。
- 镜像 tag 钉在 `grafana/loki:3.3.2`，按实际可拉取版本改。
