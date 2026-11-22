# Istio 1.30.x —— 控制面安装（Helm）+ 自定义资源（kustomize）分层
#
# 为什么分两层：
#   - istiod / ingressgateway 是上游官方 chart → 按项目约定用 Helm 管理，可用 values 覆盖
#   - Gateway / VirtualService / PeerAuthentication 是自定义 CR → 走 infra/base 的 kustomize
#   （项目铁律：有上游 Chart 的第三方组件用 Helm，自定义原生资源用 kustomize，禁止混用）
#
# 版本矩阵：Istio 1.30 官方支持 Kubernetes 1.32 ~ 1.36
#（与 ansible/inventory/group_vars/all.yml 的 kubernetes_minor=1.32 对齐）
#   Istio 1.29 已于 2026-10-15 EOL，不要再用。
#
# 部署顺序（集群起来之后，CNI 就绪之后）：
#   helm repo add istio https://istio-release.storage.googleapis.com/charts
#   helm repo update
#
#   # 0) 信任锚必须先就位（否则 istiod 首启会自签一套根 CA，形成两套信任）
#   #    helm install cert-manager（infra/cert-manager/values.yaml）
#   #    kubectl apply -k infra/cert-manager/manifests
#   #    kubectl -n istio-system wait --for=condition=Ready certificate/istio-ca --timeout=120s
#   #    bootstrap 会手动触发一次 istio-cacerts-sync（CronJob 本身 30 分钟一轮）
#   #    kubectl -n istio-system get secret cacerts
#   #    —— istiod 看到 cacerts 就用「micro-bl-ca 根签发的中间 CA」签 SVID，
#   #       与 Harbor 证书的 issuer 同指一个根（信任锚共用一份 ca.crt），
#   #       根证书本体不进任何链。
#   #    istiod 还带 --create-namespace，会复用 cert-manager 那层先建好的 istio-system。
#
#   # 1) CRD + 基础资源（必须最先）
#   helm upgrade --install istio-base istio/base -n istio-system --create-namespace \
#     --version 1.30.6 -f values-base.yaml
#
#   # 2) 控制面（prod 另加 values-istiod-prod.yaml）
#   #    副本：chart 默认 HPA min1/max5，依赖 metrics-server（Ansible 03 装）
#   helm upgrade --install istiod istio/istiod -n istio-system \
#     --version 1.30.6 -f values-istiod.yaml [-f values-istiod-prod.yaml] --wait
#
#   # 3) 南北向入口网关（NodePort，浏览器可达；prod 叠加 values-gateway-prod.yaml）
#   helm upgrade --install istio-ingress istio/gateway -n istio-system \
#     --version 1.30.6 -f values-gateway.yaml [-f values-gateway-prod.yaml]
#
#   # 4) 最后 apply CR（Gateway / VirtualService / PeerAuthentication）
#   kubectl apply -k infra/overlays/prod
#
# 验证：
#   istioctl version
#   kubectl -n istio-system get pods          # istiod / istio-ingress 均 Running
#   kubectl -n istio-system get hpa           # 副本看这里（HPA 接管，get deploy 不显示期望副本）
#   kubectl -n istio-system get svc istio-ingress   # 取 NodePort
#   kubectl -n micro-bl get pods -o jsonpath='{.items[0].spec.containers[*].name}'
#       # 业务 Pod 应有两个容器：业务容器 + istio-proxy
#
# ---------------------------------------------------------------------------
# 网格范围（关键设计，决定了 mTLS 策略与抓取方式）
#
#   注入 sidecar 的命名空间：
#     micro-bl  ← 业务三服务 + worker + web，互调用自动 mTLS + L7 治理
#                    （业务 → 中间件的出站仍经 sidecar 转发，但那一跳的加密
#                     在应用层单向 TLS，sidecar 对无 sidecar 目标自动走明文）
#
#   不注入（保持网格外）：
#     middleware   ← mysql / redis / kafka / minio（含 chart 起的 exporter 容器）
#       · 加密由应用层单向 TLS 承担：cert-manager 签服务端证书，客户端用
#         pkg/tlsx / SSL_CERT_FILE / --tls.ca-file 验内部根——端到端，覆盖
#         浏览器 NodePort 直链、Tempo 读 S3、Prometheus 抓 exporter 等
#         sidecar 管不到的路径；网格层再套一层只是双重加密
#       · 非 HTTP 协议（3306/6379/9092）从网格只能拿到 L4 连接统计，
#         可观测性早已由 mysqld/redis/kafka exporter 覆盖 → 注入只剩成本
#       · 没有 sidecar 就没有拦截：9104/9121/9308 直接明文抓取，
#         PeerAuthentication 不再需要 portLevelMtls 例外
#     observability ← Prometheus / Tempo / Loki / Grafana / otel-collector / kafka-exporter
#       · Prometheus 必须在网格外：注入 sidecar 后它对 K8s API 的访问要额外加
#         exclude，且抓取链路多一跳，收益低、坑多
#       · kafka-exporter 连 kafka.middleware:9092 走应用层单向 TLS（--tls.enabled + internal-ca），
#         无需与 Kafka 同命名空间，迁回 observability
#
#   身份控制的边界：middleware 不在网格内 → AuthorizationPolicy 管不到它，
#   "谁能连 3306/6379/9092" 将来需要时用 Cilium NetworkPolicy（L3/L4）表达。
#
# ---------------------------------------------------------------------------
# 与 Cilium 的职责边界（避免两套策略打架）
#   Istio  → L7 路由、超时/重试、服务身份 mTLS、AuthorizationPolicy（按服务账号）
#   Cilium → L3/L4 网络连通性、NetworkPolicy（按命名空间/IP）、Hubble 流量观测
#   原则：能用 Istio AuthorizationPolicy 表达的就不要写 NetworkPolicy；
#         IP/端口级的粗粒度隔离才用 Cilium，避免同一意图写两遍。
# ---------------------------------------------------------------------------
# 资源预算：3 × worker 节点，侧车按每个业务 Pod ~100m/128Mi 估算
#   istiod / gateway 副本：chart 默认 HPA min1/max5
#   （常驻 1 副本，负载高时最多 5；扩容依赖 metrics-server，否则恒为 min=1）
#   prod：反亲和 + 更大的 resources（头采 30%，见 values-istiod.yaml）

## L7 能力清单（哪些已开、哪些刻意没开）

| 能力 | 配置位置 | 状态 |
|---|---|---|
| 超时 | VirtualService `timeout` | ✅ 默认 30s；上传 1800s |
| 重试 | VirtualService `retries` | ✅ **只加在 GET 路由**（attempts 2 / perTry 5s）。POST 上传/点赞/创建不重试——非幂等，重试会产生重复数据 |
| 熔断 | DestinationRule `outlierDetection` + `connectionPool` | ✅ 连续 5 次 5xx 摘除实例 30s，最多摘 50% |
| 本地限流 | EnvoyFilter `local_ratelimit` | ✅ 网关级 200 token/s per Pod（总限额 = 副本数 × 200） |
| 权重切流 | VirtualService `route.weight` | ⏸ 未启用：业务 Pod 还没有 version 标签，现在配了也只会在同版本间分配 |
| sidecar 指标 | PodMonitor `istio-sidecars` 抓 `:15090` | ✅ 采集 `istio_requests_total` 等（只保留 4 个核心指标）；与 `calls_total` 分工：SLO 用 calls_total（入口 HTTP），网格层排障用 istio_requests_total（含 gRPC 服务间调用） |
| sidecar 调用链 | istiod `meshConfig.enableTracing` + OTel provider | ✅ sidecar span → collector:4317 → Tempo |

**关键前提**：Envoy 只看 HTTP 状态码，而本项目业务失败返回 `200 + code=4`。所以网格层的
重试/熔断/错误率**只对系统错误（500）生效**，业务失败仍由应用指标承载——这与 apperr 的
系统/业务分类天然对齐，不是缺陷。

## sidecar tracing 对 SLO 口径的影响（必须知道）

开 sidecar tracing 后，一个请求会多出 ingressgateway span 和 sidecar client/server span。
它们同样带 `http.status_code`，会被 spanmetrics 统计进去，导致 `calls_total` 重复计数。

因此 collector 的 `traces/metrics` 管道加了 `filter/only-app-spans`，只放
`instrumentation_scope.name == "micro-bl/http"` 的 span 进 spanmetrics。

**部署后必须核对**：`calls_total` 的增量应与 QPS 1:1，不能是 2~3 倍。若翻倍，说明过滤没生效
（`error_mode: ignore` 会让表达式错误退化成"不过滤"），此时 `MetricsAbsent` 不会报警，
需要手工看 `/targets` 与指标量。
