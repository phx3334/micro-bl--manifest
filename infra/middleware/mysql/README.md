# MySQL

业务使用单实例三库：`feed_user` / `feed_video` / `feed_interaction`。

## 部署要点

- Chart：`bitnami/mysql`
- 命名空间：`middleware`
- Service 名固定为 `mysql`（应用侧在 `micro-bl` 命名空间，必须用 `APP_DATABASE_HOST=mysql.middleware` 跨命名空间访问，短名 `mysql` 解析不到）
- 初始化 SQL：[init/01-databases.sql](init/01-databases.sql)
- 生产建议主从或云托管；Demo 单副本即可

```bash
kubectl -n middleware create configmap mysql-initdb \
  --from-file=01-databases.sql=init/01-databases.sql

# 凭据与容量在 values-prod.yaml（与 micro-bl-credentials 的 APP_DATABASE_PASSWORD 必须一致），
# 用 -f 而不是 --set：避免密码进 shell 历史
helm upgrade --install mysql bitnami/mysql -n middleware \
  -f values.yaml -f values-prod.yaml
```

## 指标

base values 的 metrics 段起 mysqld_exporter sidecar（9104）并创建 ServiceMonitor：

```bash
helm template mysql bitnami/mysql -n middleware -f values.yaml -f values-prod.yaml \
  | grep -iE 'serviceMonitor|mysqld-exporter'
kubectl -n middleware get servicemonitor
kubectl -n middleware logs mysql-0 -c metrics   # 报 access denied 则按 values.yaml 注释补权限
```

凭据必须同值：中间件侧 `values-prod.yaml` 的 `auth.username/password`，业务侧
`micro-bl-credentials` Secret 的 `APP_DATABASE_PASSWORD`；两边写错一个业务就连不上库。
root 账号仅保留给运维与 mysqld_exporter。
