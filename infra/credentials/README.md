# 凭据契约（Credentials Contract）

凭据**不随仓库分发**。这里是“谁需要哪些 Secret、键名是什么”的唯一清单；
具体值由 SealedSecret（推荐）或 CI/ansible 在部署时注入。

## 契约表

| Secret | 命名空间 | 键 | 消费者 | 配置位置 |
|---|---|---|---|---|
| `minio-credentials` | `middleware` | `rootUser`、`rootPassword` | MinIO chart（`auth.existingSecret`） | `infra/middleware/minio/values-prod.yaml` |
| `mysql-credentials` | `middleware` | `mysql-password`、`mysql-root-password`、`mysql-replication-password`（三个键都必须存在，键名固定） | bitnami/mysql（`auth.existingSecret`） | `infra/middleware/mysql/values-prod.yaml` |
| `redis-credentials` | `middleware` | `redis-password` | bitnami/redis（`auth.existingSecret` + `existingSecretPasswordKey`） | `infra/middleware/redis/values-prod.yaml` |
| `harbor-credentials` | `platform-system` | `HARBOR_ADMIN_PASSWORD`、`secretKey`（键名固定；secretKey 必须 16 字符） | Harbor chart（`existingSecretAdminPassword` / `existingSecretSecretKey`） | `cicd/harbor/values-prod.yaml` |
| `micro-bl-credentials` | `micro-bl` | `APP_JWT_ACCESS_TOKEN_SECRET`、`APP_JWT_REFRESH_TOKEN_SECRET`、`APP_DATABASE_PASSWORD`、`APP_REDIS_PASSWORD`、`APP_MINIO_ACCESS_KEY`、`APP_MINIO_SECRET_KEY` | 业务 chart（`secret.existingSecret`，`envFrom.secretRef` 整体注入） | `apps/micro-bl/values-prod.yaml` |
| `tempo-s3` | `observability` | `accessKey`、`secretKey` | Tempo（`secretKeyRef` 逐项注入） | `observability/tempo/overlays/prod` |
| `grafana-admin` | `observability` | `adminPassword` | Grafana（`secretKeyRef` 注入 `GF_SECURITY_ADMIN_PASSWORD`） | `observability/grafana/base/deployment.yaml` |
| `harbor-pull` | `micro-bl` | `.dockerconfigjson` | 业务 Pod 拉镜像（`imagePullSecrets`） | `apps/micro-bl/values.yaml` |
| `harbor-push` | `platform-system` | `.dockerconfigjson` | Tekton BuildKit/Skopeo 推镜像 | `cicd/tekton/tasks/build-scan-push.yaml` |
| `github-webhook-secret` | `platform-system` | `secretToken` | Tekton EventListener HMAC 校验 | `cicd/tekton/triggers/event-listener.yaml` |
| `gitops-token` | `platform-system` | `token` | Tekton 回写 infra 仓库 | `cicd/tekton/tasks/update-gitops.yaml` |

> 跨 Secret 一致性：`mysql-credentials.mysql-password` == `micro-bl-credentials.APP_DATABASE_PASSWORD`；
> `redis-credentials.redis-password` == `micro-bl-credentials.APP_REDIS_PASSWORD`；
> `harbor-credentials` 无跨 Secret 约束（管理员密码独立设置，`secretKey` 必须 16 字符）。
> ArgoCD 管理员密码以 bcrypt 哈希存于 `cicd/argocd/bootstrap/argo-cd-values.yaml`（哈希非明文）。

> K8s Secret 不能跨命名空间引用，所以同一组 MinIO 凭据在三个命名空间各有一份副本。
> 想彻底消除副本，需要 External Secrets Operator 或 Reflector；当前用 SealedSecret
> 保证“仓库里都是密文”。

## 凭据来源

只保留 prod 路径：`values-prod.yaml` 只写 `existingSecret` 引用，仓库里没有任何明文值。
Secret 缺失时 Pod 会停在 `CreateContainerConfigError`（显式失败，不会静默用错值）。

**密码本体不写入任何仓库文件**：README 命令里的 `<...>` 占位符由运维替换为实际值，
ArgoCD 密码以 bcrypt 哈希入库（哈希不可逆，等同非明文）。

`harbor-pull` / `harbor-push` / `github-webhook-secret` / `gitops-token` 不随 kustomize
下发，全部创建命令见 [project-infra/README.md](../../README.md)：step 4（基础凭据，
含上表前 7 个 Secret）与 step 7（Harbor robot / Tekton 凭据）。

## 生成 SealedSecret（集群起来后执行）

prerequisites：`infra/sealed-secrets` 已安装、`kubeseal` 已加入 PATH。

```bash
# 1) 明文只写临时文件，绝不提交
cat > /tmp/minio-credentials.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: minio-credentials
  namespace: middleware
type: Opaque
stringData:
  rootUser: phx
  rootPassword: REPLACE_WITH_STRONG_PASSWORD
EOF

# 2) 封印（strict scope：绑定名称 + 命名空间，换名/换空间都解不开）
kubeseal --controller-namespace kube-system --format yaml \
  < /tmp/minio-credentials.yaml > prod/minio-credentials.sealed.yaml
rm -f /tmp/minio-credentials.yaml

# 3) 提交密文，然后 apply
kubectl apply -f prod/minio-credentials.sealed.yaml
```

业务凭据同理，把 `name` 改为 `micro-bl-credentials`、`namespace` 改为 `micro-bl`、
`stringData` 换成契约表里的 6 个键；Tempo 的 `tempo-s3` 换到 `observability`；
`harbor-pull` / `harbor-push` 用 `kubectl create secret docker-registry` 生成后
再按同样方式封印。

> 仓库里只放 `.sealed.yaml`（密文）。明文 YAML、备份密钥、`.env` 一律不入库。
