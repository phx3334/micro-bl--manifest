# MinIO

用途：视频上传源、转码产物、封面、头像。数据库只保存对象 key。

## 部署要点

- Chart：`bitnami/minio`
- Service 名固定为 `minio`
- 应用启动时自动创建 bucket（默认 `micro-bl`）
- 生产建议媒体桶与 Velero 备份桶分离、独立凭据
- `APP_MINIO_ENDPOINT` 必须同时保证 Pod 与浏览器可达：
  - Pod 内可用 `minio.middleware:9000`（ClusterIP）
  - 浏览器消费视频/封面/头像直链 → 开 NodePort `30900`。
    MinIO 是"给人看的"媒体源站，不属于纯内部组件，因此 prod 也不收敛到 ClusterIP。
- Console：新版 `bitnami/minio` 已移除内置 Console（没有 `consoleService` 键），
  需要管理界面时用 `mc` 客户端或独立部署 Object Browser；旧版 chart 可补 NodePort `30901`。

```bash
# 凭据/容量/桶清单在 values-prod.yaml（与 micro-bl-credentials 的
# APP_MINIO_ACCESS_KEY / APP_MINIO_SECRET_KEY 必须一致），
# 用 -f 而不是 --set：避免凭据进 shell 历史
helm upgrade --install minio bitnami/minio -n middleware \
  -f values.yaml -f values-prod.yaml
```

凭据只走外部 Secret：`auth.existingSecret: minio-credentials`，仓库里不出现任何值。
Secret 由 SealedSecret 注入（键 `rootUser` / `rootPassword`），流程见
[infra/credentials/README.md](../../credentials/README.md)。

## 桶

`defaultBuckets` 一次建齐：`micro-bl` 与 `tempo-prod`
（`tempo-prod` 必须与 `observability/tempo/overlays/prod` 的 `TEMPO_S3_BUCKET` 对应）。
业务桶业务代码启动时也会自建，这里双保险。

## 指标

MinIO **服务端自带** `/minio/v2/metrics/cluster`，与 API 共用 9000 端口（新版 chart 无独立 metrics 端口、无 Console），不需要额外 exporter：

- 开启：base values 的 `extraEnvVars` 设 `MINIO_PROMETHEUS_AUTH_TYPE=public`（免鉴权，集群内抓取）；
- 抓取：[servicemonitor-minio.yaml](../../../observability/prometheus/manifests/servicemonitor-minio.yaml) 指向 minio Service 的 `api` 端口，30s 一次；
- 看板/告警：`micro-bl 中间件` 看板的容量/节点面板，`MinioCapacityLow`（剩余容量 < 20%）、`MinioNodesOffline` 告警——**容量类问题不可自愈，是对象存储生产告警的基线**，业务 5xx 只能反映急性故障。

收紧方案（对外暴露的环境）：`auth_type` 改 `cfg`，用 `mc admin prometheus generate` 生成 token 挂 Secret，
ServiceMonitor 的 endpoint 配 `authorization.bearerFromSecret`。

部署后验证端口名（chart 版本不同端口名可能变化）：

```bash
kubectl -n middleware get svc minio -o jsonpath='{.spec.ports[*].name}'
# 端口名不是 api 时改 servicemonitor-minio.yaml 的 endpoints.port，然后：
curl -s --cacert <内部根 CA> https://minio.middleware:9000/minio/v2/metrics/cluster | head
```
