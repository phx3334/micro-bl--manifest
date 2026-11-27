# project-infra（micro-bl--manifest）

Kubernetes 生产环境的完整基础设施声明：Terraform 建云资源 → Ansible 装集群 → Kustomize/Helm 部署平台组件与应用。

## 目录结构

```
project-infra/
├── terraform/        # 阿里云资源定义（IaC）：VPC、安全组、6 台 ECS、2 个 SLB、EIP、RAM 角色
│                     #   apply 后生成 ansible/inventory/hosts.ini；state 文件勿丢（destroy 靠它）
├── ansible/          # 集群安装与配置
│   ├── inventory/    #   hosts.ini（terraform 生成）+ group_vars（版本、镜像源、组件开关）
│   ├── playbooks/    #   00 预检 → 01 节点初始化 → 02 kubeadm 引导 → 03 平台组件安装
│   └── roles/        #   common / containerd / kubeadm_master / kubeadm_worker / bootstrap
├── infra/            # 平台基础设施（Kustomize/Helm values）
│   ├── base/         #   命名空间、Istio Gateway/VirtualService、RBAC
│   ├── overlays/prod/#   prod 补丁（域名、host 等环境相关字段）
│   ├── cilium/       #   CNI（含 Hubble UI）
│   ├── istio/        #   服务网格（ingressgateway 即业务入口）
│   ├── cert-manager/ #   内部 CA 与各组件证书签发
│   ├── csi-alicloud/ #   阿里云云盘 CSI + StorageClass
│   ├── sealed-secrets/#  密钥加密（凭据不入库，见 credentials/README.md）
│   ├── credentials/  #   凭据契约：谁需要哪些 Secret（值不随仓库分发）
│   └── middleware/    #   MySQL / Redis / Kafka / MinIO 的 chart values
├── cicd/             # CI/CD 平台
│   ├── tekton/       #   流水线：构建、扫描、推镜像、回写 GitOps
│   ├── tekton-platform/
│   ├── argocd/       #   GitOps：bootstrap 与 prod 应用
│   └── harbor/       #   私有镜像仓库
├── observability/    # 可观测性（Prometheus Operator + kustomize）
│   ├── prometheus/   #   指标采集、告警规则（ServiceMonitor/PrometheusRule）
│   ├── grafana/      #   看板（数据源与 dashboard 全部 IaC provisioning）
│   ├── loki/         #   日志聚合
│   ├── tempo/        #   链路追踪（数据存 MinIO）
│   ├── otel-collector/#  日志/指标/链路采集网关与 agent
│   └── kafka-exporter/
├── apps/micro-bl/    # 业务应用 Helm chart（部署、服务、KEDA ScaledObject）
└── README.md         # 部署 runbook（本文件的详细操作步骤）
```

## 端口清单

### 安全组放行（来源已收敛，见 terraform/network.tf）
`node_port_cidr`:允许访问 NodePort 入口的来源 IP 范围
`ssh_cidr`:允许进行对master进行ssh连接的ip的范围

| 端口 | 协议 | 用途 | 来源 |
|---|---|---|---|
| 22 | TCP | SSH 管理 | `ssh_cidr`（本机公网 IP/32） |
| 6443 | TCP | Kubernetes apiserver（kubectl 直连） | `ssh_cidr` |
| 6443 | TCP | 同上 | `100.64.0.0/10`（内网 CLB 健康检查源段） |
| 30080 | TCP | Istio ingressgateway 的 NodePort（公网 SLB 健康检查探测它） | `100.64.0.0/10` |
| 30003 | TCP | Harbor HTTPS | `node_port_cidr`（本机公网 IP/32） |
| 30080 | TCP | Istio ingressgateway（业务/媒体站入口） | `node_port_cidr` |
| 30081 | TCP | Tekton EventListener（Git webhook） | `node_port_cidr` |
| 30082 | TCP | ArgoCD UI | `node_port_cidr` |
| 30300 | TCP | Grafana 看板 | `node_port_cidr` |
| 30400 | TCP | Cilium Hubble UI | `node_port_cidr` |
| 30443 | TCP | Istio ingressgateway HTTPS（公网 SLB 443 的后端，TLS 在此终结） | `node_port_cidr`、`100.64.0.0/10`（SLB 健康检查）、Cloudflare 回源 IP 段（见 network.tf `cloudflare_origin`） |
| 30900 | TCP | MinIO API（浏览器直链） | `node_port_cidr` |
| 全部 | all | VPC 内互通（etcd 2379/2380、kubelet 10250、Cilium VXLAN、NodePort 互访） | `vpc_cidr` |
| 全部 | all | 出方向 | `0.0.0.0/0` |

- `ssh_cidr` / `node_port_cidr` 在 variables.tf 中强制校验：禁止留空、禁止 `0.0.0.0/0`。

### 负载均衡监听（terraform/slb.tf）

| SLB | 监听 | 后端 | 说明 |
|---|---|---|---|
| 内网 `micro-bl-apiserver` | TCP 6443 | 3 台 master:6443 | kubeadm `controlPlaneEndpoint`（固定私网 VIP） |
| 公网 `micro-bl-public` | TCP 443 | 全部 6 节点:30443 | 浏览器与 Cloudflare CDN 回源入口；Istio Gateway 在 443 终止 TLS（证书 `*.temporary-demo.xyz`，cert-manager + Cloudflare DNS-01 自动签发续期），按 Host/SNI 分流业务站与 `media.temporary-demo.xyz` |

### 集群内部端口（ClusterIP，不对公网暴露）

MySQL 3306、Redis 6379 / Sentinel 26379、Kafka 9092、MinIO 9000、Loki 3100、Tempo 3200、Prometheus 9090 等——排障用 `kubectl port-forward`：

```powershell
# Prometheus UI → http://localhost:9090
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090

# MySQL：本机客户端连 localhost:3306（密码取自 mysql-credentials Secret）
kubectl -n middleware port-forward svc/mysql 3306:3306

# Loki 日志查询
kubectl -n monitoring port-forward svc/loki 3100:3100
curl "http://localhost:3100/loki/api/v1/query_range?query={app=\"web\"}&limit=5"
```

## IP 地址清单

| 范围/地址 | 用途 |
|---|---|
| `10.0.0.0/16` | VPC 网段 |
| `10.0.1.0/24` | 交换机网段（节点与 CLB） |
| `10.0.1.10` ~ `10.0.1.12` | 3 台 master 固定私网 IP（重建不漂移） |
| `10.0.1.20` ~ `10.0.1.22` | 3 台 worker 固定私网 IP |
| `10.244.0.0/16` | Pod 子网（Cilium） |
| `10.96.0.0/12` | Service 子网（ClusterIP） |
| `100.64.0.0/10` | 阿里云保留段：SLB 健康检查源（安全组需单独放行） |
| 统一入口 EIP（绑 apiserver SLB） | SSH、kubectl、全部 NodePort 服务的固定公网地址；REPLACE_WITH_SERVER_IP、证书 IP SAN 均指向它，SLB 自动摘除故障 master（`terraform output entry_eip`） |
| 公网 SLB 地址 | 业务/媒体站 443 入口（`terraform output public_slb_address`） |
| `216.23.123.76/32` | 我自己的日常使用的机器 |