# Redis（Sentinel 高可用）

用途：验证码、用户/视频缓存、点赞集合、热度 ZSet。

## 部署要点

- Chart：`bitnami/redis` **23.1.3**（sentinel/TLS 键名按该版本核对）
- 拓扑：**1 主 2 从 + Sentinel**（哨兵与 redis 同 Pod，共 3 个数据节点）
- Service 名固定为 `redis`：哨兵模式下 chart 会关闭 master/replicas 两个 Service，
  只用这一个 Service 同时暴露数据端口 `6379` 与哨兵端口 `26379`
- 必须开启持久化：`appendonly yes` + RDB 快照
- 密码通过 Secret 注入 `APP_REDIS_PASSWORD`；`auth.sentinel: true` 时哨兵也要求密码

```bash
# 凭据与容量在 values-prod.yaml（与 micro-bl-credentials 的 APP_REDIS_PASSWORD 必须一致），
# 用 -f 而不是 --set：避免密码进 shell 历史
helm upgrade --install redis bitnami/redis -n middleware \
  --version 23.1.3 \
  -f values.yaml -f values-prod.yaml
```

## 高可用验证（面试可演示）

```bash
# 1) 3 个节点（redis-node-0/1/2），每个 Pod 里有两个容器：redis + sentinel
kubectl -n middleware get pods -l app.kubernetes.io/name=redis

# 2) 查当前主节点
kubectl -n middleware exec redis-node-0 -c sentinel -- \
  redis-cli -p 26379 --tls --cacert /opt/bitnami/redis/certs/ca.crt \
  -a "$REDIS_PASSWORD" sentinel get-master-addr-by-name mymaster

# 3) 杀掉当前主节点，观察哨兵在数秒内完成选主
kubectl -n middleware delete pod <current-master-pod>

# 4) 再看一次主节点地址已经变化；业务侧无需重启（go-redis FailoverClient 自动重连）
```

## 业务侧配置

| 环境变量 | 值 | 说明 |
|---|---|---|
| `APP_REDIS_SENTINEL_ADDRS` | `redis.middleware:26379` | 非空时走 `FailoverClient`；本地留空则直连 `host:port` |
| `APP_REDIS_MASTER_NAME` | `mymaster` | 必须与 chart 的 `sentinel.masterSet` 一致 |
| `APP_REDIS_TLS_ENABLED` | `true` | 哨兵与数据节点共用同一套 TLS 配置 |
| `APP_REDIS_TLS_SERVER_NAME` | 空 | 为空时取 `host`（`redis.middleware`），证书 SAN 已覆盖 |

## 指标

base values 的 metrics 段起 redis_exporter sidecar（9121）并创建 ServiceMonitor，随
`-f values.yaml` 自动生效。验证：

```bash
helm template redis bitnami/redis -n middleware --version 23.1.3 \
  -f values.yaml -f values-prod.yaml | grep -iE 'serviceMonitor|redis-exporter'
kubectl -n middleware get servicemonitor   # 应出现 redis 相关对象
```

Redis 不可用时服务会降级到 MySQL（点赞判重、缓存回源）。

## 已有集群从 standalone 升级的注意点

- 切到 sentinel 模式会新建 `redis-node-*` StatefulSet 与 PVC，旧的 standalone PVC 不会自动迁移；
  演示环境建议 `helm uninstall` 后重装，需要保留数据时先导出 RDB/AOF。
- `redis-master` Service 在 sentinel 模式下不再创建，任何直接引用它的配置都要改成 `redis`。
