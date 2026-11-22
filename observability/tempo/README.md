# Tempo

链路存储，单机模式（`target: all`），对象存储后端指向 MinIO。只保留 prod overlay。

## 目录

```
tempo/
├── base/
│   ├── tempo.yaml          # 配置：S3 后端 + 端口；桶名/保留期用 ${ENV} 占位
│   ├── deployment.yaml     # Deployment + Service + WAL 的 PVC
│   └── kustomization.yaml  # configMapGenerator 从 tempo.yaml 生成 ConfigMap
├── overlays/
│   └── prod/               # 桶 tempo-prod、保留 14d、大资源、凭据由 SealedSecret 注入
└── README.md
```

## prod 配置

| 项 | 值 | 实现 |
|---|---|---|
| 桶名 | `tempo-prod` | env `TEMPO_S3_BUCKET` |
| 保留期 | 336h（14d） | env `TEMPO_BLOCK_RETENTION` |
| 资源 | 500m/512Mi ~ 2C/2Gi | patch |
| S3 凭据 | 外部 `tempo-s3` Secret（SealedSecret） | 见 `infra/credentials/README.md` |

配置本身只有一份：`block_retention` 和 `bucket` 都是 `${ENV:-默认值}`，由 Deployment 注入，靠 `-config.expand-env=true` 展开。

## 部署

```bash
kubectl apply -k observability/tempo/overlays/prod
```

## 前置：桶

Tempo **不会自动创建 bucket**，直接启动会报 no such bucket。两种方式（任选）：

1. **推荐**：MinIO chart 的 `defaultBuckets` 已建好 `tempo-prod`
   （见 `infra/middleware/minio/values-prod.yaml`）——先装 MinIO 再装 Tempo 即可；
2. 手动兜底（MinIO 是存量实例时）：

```bash
kubectl -n middleware exec deploy/minio -- sh -c \
  'mc alias set local http://localhost:9000 <minio-root-user> <minio-root-password> && mc mb -p local/tempo-prod'
```

## 端口

| 端口 | 用途 |
|---|---|
| 4317 / 4318 | OTLP gRPC / HTTP（collector 推送到 `tempo:4317`） |
| 3200 | HTTP 查询，Grafana 数据源填 `http://tempo:3200` |

## 验证

```bash
kubectl -n observability rollout status deploy/tempo
kubectl -n observability port-forward svc/tempo 3200:3200
curl -s localhost:3200/ready
curl -s 'localhost:3200/api/search?limit=5' | head
```

## 坑

- **本地现在只留 WAL**（2Gi PVC），数据主体在 MinIO；盘满的告警意义下降了，但 MinIO 那边要盯容量。
- MinIO 必须开 `forcepathstyle: true`，否则 Tempo 的 S3 SDK 会拼出 `bucket.minio:9000` 这种非法域名。
- `region` 必须非空（AWS SDK 要求），MinIO 不校验，填 `us-east-1` 即可。
- 保留期靠 compactor 的 `block_retention`，**不是删文件**；compactor 没跑起来数据会一直涨。
- 镜像 tag 钉在 `grafana/tempo:2.6.1`，按实际可拉取版本改。
- 采样在 collector 侧完成（头采 + 尾采），Tempo 只负责存。
