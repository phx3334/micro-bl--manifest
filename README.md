# project-infra（micro-bl--manifest）

只保留 **prod 一套部署**。Terraform 拉起阿里云节点，Ansible 完成 kubeadm 与平台组件 bootstrap，ArgoCD 接管 `infra/overlays/prod` 与业务 Chart；MySQL / Redis / Kafka / MinIO 与观测栈按各组件 README 手工安装。

## 目录

```
terraform/          # VPC / 交换机 / 安全组 / CLB / ECS / 生成 ansible inventory
ansible/            # 00-preflight → 01-provision → 02-kubeadm → 03-bootstrap
infra/              # Cilium / Istio / cert-manager / sealed-secrets / middleware / overlays/prod
observability/      # Prometheus / Tempo / Loki / Grafana / otel-collector / kafka-exporter
cicd/               # Harbor values / Tekton 资源 / ArgoCD bootstrap 与 prod Applications
apps/micro-bl/   # 业务 Helm Chart（只有 values-prod.yaml）
```

## 前置

- Terraform、Ansible（Windows 建议 WSL）、kubectl、helm。
- 阿里云按量付费账号；`terraform.tfvars` 必填 `ssh_cidr` 与 `ssh_public_key`。
- 国内网络建议先实测 Istio chart（Google Storage）、quay.io、Docker Hub、ghcr.io；不通时先准备镜像代理/同步。
- 演示当天把 `internet_max_bandwidth_out` 临时调到 100 Mbps，拉完镜像再按需降回；默认 10 Mbps 会非常慢。

## 1. Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# 填 ssh_cidr=<你的公网IP>/32、ssh_public_key=<~/.ssh/id_ed25519.pub>、
# node_port_cidr 建议同样收敛到自己的 IP
terraform init
terraform apply
```

- `terraform.tfstate` 是本地文件且被 gitignore；**不要丢**，演示结束要靠它 `terraform destroy`，否则实例/CLB 会继续计费。
- 公网 IP 不是 EIP：实例 stop/start 后可能变化，Harbor/MinIO 证书 SAN、Gateway host、Tekton registry 都会失效。演示当天不要 stop/start；需要暂停就改用 EIP。
- `availability_zone` 自动选择只按 worker 规格过滤；如果 master 规格在该 AZ 无货，手动指定 `availability_zone`。
- `key_pair_name` 默认 `micro-bl`，地域内已有同名密钥对时需改名或 import。
- Terraform 会创建 CSI 专用 RAM 角色 `micro-bl-csi` 并绑定到节点；RAM 用户需要临时具备创建角色/策略的权限（例如 `AliyunRAMFullAccess`），否则 apply 会在 `alicloud_ram_role` 处失败。
- MySQL 使用动态 ESSD，云盘不在 Terraform state 里；`terraform destroy` 前先删除 MySQL PVC/PV，确认阿里云控制台没有残留云盘。

Terraform 会生成 `ansible/inventory/hosts.ini`（当前为空文件，apply 后才有内容）。

## 2. 替换服务器 IP

回到仓库根目录：

```bash
cd ..   # 从 terraform/ 回到 project-infra/
```

所有 `REPLACE_WITH_SERVER_IP` 统一填 **第一台 master 的公网 IP**（`terraform output master_public_ips[0]`）。Harbor 与 MinIO 证书的 IP SAN 只签这一台，填别的节点会 x509 失败。

```bash
grep -rn "REPLACE_WITH_SERVER_IP" .
```

重点文件：

- `apps/micro-bl/values.yaml`：`images.registry`
- `apps/micro-bl/values-prod.yaml`：`config.minio.endpoint`
- `infra/overlays/prod/patches/istio-gateway-host.yaml`
- `infra/overlays/prod/patches/istio-virtualservice-host.yaml`
- `infra/cert-manager/manifests/harbor-certificate.yaml`
- `infra/cert-manager/manifests/middleware-certificates.yaml`（MinIO IP SAN）
- `cicd/tekton/triggers/trigger-template.yaml`：`image-registry`

`03-install-bootstrap` 的占位符检查会忽略注释行，只匹配真实配置值。

## 3. Ansible

```bash
cd ansible
ansible-playbook playbooks/00-preflight.yml
ansible-playbook playbooks/01-provision-nodes.yml
ansible-playbook playbooks/02-bootstrap-kubeadm.yml
ansible-playbook playbooks/03-install-bootstrap.yml
```

`03` 会安装：local-path、阿里云云盘 CSI（只启用 disk 驱动）、metrics-server、KEDA、cert-manager + 内部 CA、sealed-secrets、Istio、Harbor、Tekton 控制器、ArgoCD，并手动触发一次 `internal-ca-distributor` 和 `istio-cacerts-sync`，保证 istiod 首启前已有内部 CA。

CSI 只创建 `alicloud-disk-essd` StorageClass，不设为默认；默认仍是 local-path。只有 MySQL 的 PVC 显式使用 `alicloud-disk-essd`，其他组件继续 local-path。想关闭 CSI：`-e install_csi=false`。

## 4. 基础 prod 凭据（Harbor 相关的在 step 7）

回到仓库根目录执行后续命令：

```bash
cd ..   # 从 ansible/ 回到 project-infra/
```

ArgoCD 默认同步 prod，业务/MinIO/Tempo 都引用外部 Secret。仓库里没有明文，也不应提交明文。

```bash
# 1) 业务 6 个键
kubectl -n micro-bl create secret generic micro-bl-credentials \
  --from-literal=APP_JWT_ACCESS_TOKEN_SECRET="$(openssl rand -hex 32)" \
  --from-literal=APP_JWT_REFRESH_TOKEN_SECRET="$(openssl rand -hex 32)" \
  --from-literal=APP_DATABASE_PASSWORD="<mysql-phx-password>" \
  --from-literal=APP_REDIS_PASSWORD="<redis-password>" \
  --from-literal=APP_MINIO_ACCESS_KEY="<minio-root-user>" \
  --from-literal=APP_MINIO_SECRET_KEY="<minio-root-password>"

# 2) MinIO chart 的 root 凭据
kubectl -n middleware create secret generic minio-credentials \
  --from-literal=rootUser="<minio-root-user>" \
  --from-literal=rootPassword="<minio-root-password>"

# 3) Tempo 的 S3 凭据 + Grafana 管理员密码
kubectl -n observability create secret generic tempo-s3 \
  --from-literal=accessKey="<minio-root-user>" \
  --from-literal=secretKey="<minio-root-password>"
kubectl -n observability create secret generic grafana-admin \
  --from-literal=adminPassword="<strong-password>"
```

生产建议用 SealedSecret 固化上述 Secret；临时演示用上面的命令即可。

## 5. 中间件（手工 Helm，顺序不能反）

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# MySQL：先建 initdb ConfigMap
# values-prod 会把 PVC 放到 alicloud-disk-essd（03 已安装 CSI）
kubectl -n middleware create configmap mysql-initdb \
  --from-file=01-databases.sql=infra/middleware/mysql/init/01-databases.sql
helm upgrade --install mysql bitnami/mysql -n middleware --version <chart-version> \
  -f infra/middleware/mysql/values.yaml -f infra/middleware/mysql/values-prod.yaml

# 观察 MySQL 动态 ESSD 的挂载链路
kubectl -n middleware get pvc
kubectl get pv
kubectl get volumeattachment
kubectl -n middleware describe pvc data-mysql-0
kubectl -n middleware describe pod mysql-0
# 阿里云控制台也能看到对应的 ESSD 云盘

# Redis（sentinel，1 主 2 从）
helm upgrade --install redis bitnami/redis -n middleware --version 23.1.3 \
  -f infra/middleware/redis/values.yaml -f infra/middleware/redis/values-prod.yaml

# Kafka（KRaft 单节点；advertisedHost 已指向 kafka.middleware.svc.cluster.local）
helm upgrade --install kafka bitnami/kafka -n middleware --version <chart-version> \
  -f infra/middleware/kafka/values.yaml -f infra/middleware/kafka/values-prod.yaml

# MinIO（先于 Tempo，defaultBuckets 会建 tempo-prod）
helm upgrade --install minio bitnami/minio -n middleware --version <chart-version> \
  -f infra/middleware/minio/values.yaml -f infra/middleware/minio/values-prod.yaml
```

MySQL / Kafka / MinIO 的 chart 版本必须显式钉住：先用 `helm search repo bitnami/mysql --versions`
等命令选一个与 values 键名匹配的版本，再替换 `<chart-version>`，避免 latest 改键导致渲染失败。

## 6. 观测栈（手工）

```bash
# Prometheus Operator 全家桶
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  -n observability --version 65.8.1 \
  -f observability/prometheus/values.yaml -f observability/prometheus/values-prod.yaml

# operator CRD 就绪后再 apply CR
kubectl apply -k observability/prometheus/manifests

# 采集器 / 存储 / 看板
kubectl apply -k observability/otel-collector/overlays/prod
kubectl apply -k observability/tempo/overlays/prod
kubectl apply -k observability/loki/overlays/prod
kubectl apply -k observability/grafana/overlays/prod
kubectl apply -k observability/kafka-exporter
```

prod 的 otel-collector 固定 1 副本：`tail_sampling` + `spanmetrics` 是进程内有状态组件，多副本会被 Service 打散 trace 和指标。需要扩容时改成 gateway + `loadbalancing` exporter（routing_key: traceID）+ 独立采样层，而不是直接加副本。

## 7. Harbor 与 Tekton

- Harbor：建项目 `micro-bl`；建 `robot$push`（push/pull）和 `robot$pull`（pull）；robot token 分别用于 `harbor-push` 与 `harbor-pull`。
- Tekton / 业务拉镜像凭据（不要提交真实值）：

```bash
kubectl -n micro-bl create secret docker-registry harbor-pull \
  --docker-server="<master1-public-ip>:30003" \
  --docker-username='robot$pull' --docker-password="<harbor-pull-robot-token>"

kubectl -n platform-system create secret generic github-webhook-secret \
  --from-literal=secretToken="$(openssl rand -hex 32)"
kubectl -n platform-system create secret generic gitops-token \
  --from-literal=token="<GitHub fine-grained PAT，仅 infra 仓 Contents: Read and write>"
kubectl -n platform-system create secret docker-registry harbor-push \
  --docker-server="<master1-public-ip>:30003" \
  --docker-username='robot$push' --docker-password="<harbor-push-robot-token>"
```

- 如果业务仓库（`micro-bilibili`）是私有的，`build-app` 的 `git-clone` 还需要一个
  `basic-auth` Secret（`.gitconfig` + `.git-credentials`）；公开仓库可跳过。

- 应用 Tekton 业务资源（当前没有 ArgoCD Application 负责它）：

```bash
kubectl apply -k cicd/tekton
```

- GitHub 仓库 Webhook：Payload URL `http://<master1-public-ip>:30081`，Content type `application/json`，Secret 填上面 `secretToken`，只订阅 push（main 分支）。

## 8. Git push 与 ArgoCD

`project-infra` 是独立 Git 仓库（remote 为 `micro-bl--manifest`）。先 commit/push，ArgoCD 根 Application 才能拉到内容。
如果仓库是私有的，还需要在 ArgoCD 里配置该仓库的 repository credentials。

```bash
# 当前目录应为 project-infra 根目录
git add -A
git commit -m "prod only"
git push origin main
```

然后在 ArgoCD 里确认 `root` → `platform-infra` / `apps-micro-bl` 同步成功。首次业务 Pod 需要等 Tekton 构建出 commit SHA 镜像并回写 `apps/micro-bl/values-prod.yaml` 后才能 Ready。

首次部署是空库：`values-prod.yaml` 的 `autoMigrate` 已设为 `true`。如果想避免两个副本并发跑 DDL，
可以先把三个服务的 `replicas` 临时改成 1，建表完成后恢复 2 并把 `autoMigrate` 改回 `false`。

## 9. 验证

```bash
kubectl get nodes -o wide
kubectl -n micro-bl get pods
kubectl -n micro-bl get svc
curl -k https://<master1-ip>:30003/api/v2.0/healthz
curl -s http://<master1-ip>:30082/healthz
```

浏览器播放 MinIO 视频前，把内部根 CA（`micro-bl-ca` 的 `ca.crt`）导入系统/浏览器信任库；否则 `https://<master1-ip>:30900/...` 会证书告警。

## 10. 销毁

先删 MySQL 动态云盘，再 destroy 集群：

```bash
helm uninstall mysql -n middleware
kubectl -n middleware delete pvc data-mysql-0
# 等 PV 变成 Released/Deleted，确认阿里云控制台没有残留 ESSD
kubectl get pv

cd terraform
terraform destroy
```

CSI 动态创建的云盘不在 Terraform state 里，漏删会继续计费。

确认 ECS、CLB、数据盘、VPC、动态 ESSD 全部释放；按量付费下最贵的是 3 台 8C16G worker 和 CLB，别只删 ECS 留 CLB。
