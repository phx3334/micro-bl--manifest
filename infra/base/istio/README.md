# Istio（Sidecar 模式）

目标：以 Sidecar 模式提供 mTLS 与 L7 流量治理，不替换 Cilium CNI——Cilium 管四层及以下，Istio 管七层。

```bash
helm repo add istio https://istio-release.storage.googleapis.com/charts
helm upgrade --install istio-base istio/base -n istio-system --create-namespace
helm upgrade --install istiod istio/istiod -n istio-system
# 南北向入口网关（外部流量进网格，与业务 sidecar 同为 Envoy）
helm upgrade --install istio-ingressgateway istio/gateway -n istio-system
```

纳管业务命名空间（开启 sidecar 自动注入）：

```bash
kubectl label namespace micro-bl istio-injection=enabled
```

## 南北向路由资源（kustomize 管理）

原先的 K8s Ingress 已移除，入口改由 Gateway + VirtualService 承担：

| 资源 | 位置 | 命名空间 | 说明 |
|------|------|----------|------|
| Gateway | [gateway.yaml](gateway.yaml) | `istio-system` | 必须放在 istiod 的配置命名空间，否则 ingressgateway 不认 |
| VirtualService | [virtualservice.yaml](virtualservice.yaml) | `micro-bl` | 四条路由，前缀 `/` 必须放最后一条 |

```bash
# 部署前先把 infra/overlays/prod/patches/istio-gateway-host.yaml 和
# istio-virtualservice-host.yaml 里的 REPLACE_WITH_SERVER_IP 换成第一台 master 公网 IP
kubectl apply -k infra/overlays/prod
```

base 保持环境无关（通配 host），只有 prod overlay。**只用 HTTP，不启用边缘 TLS → 不需要域名和证书**；网格内部的 mTLS 由 Istio 自动签发轮换，无需手工配置。

host 填公网 IP 后，直接用 `http://<master1-IP>:30080` 访问，不需要改 hosts：

```bash
kubectl -n istio-system get svc istio-ingress   # 确认 80:30080/TCP

curl http://<master1-IP>:30080/api/v1/video/list
```

云服务器还要在**安全组/防火墙放行该 NodePort**（默认范围 30000-32767），否则浏览器连不上。

**为什么 host 必须写 IP**：HTTP/1.1 的 `Host` 头由浏览器按地址栏自动填充，访问 `http://1.2.3.4:30080` 时发的是 `Host: 1.2.3.4:30080`；Gateway 的 `hosts` 只接受与之匹配的值，写成别的域名就会返回 `404 NR`（no route）——这不是网络不通，是 Host 对不上。

以后要绑域名：把两处 patch 的 IP 换成域名，再在 DNS 把域名解析到该服务器 IP。

原先 Ingress 上的 nginx 注解（1024m 上传体、1800s 超时）已迁移为 VirtualService 的 `timeout: 1800s`；Istio 默认 15s 超时，漏配会把视频上传直接切断。

## 控制面安装

istiod / ingressgateway 走 Helm（官方 chart，见 [infra/istio/](../../istio/)），本目录只管 CR：
Gateway、VirtualService、PeerAuthentication。安装顺序与版本矩阵见 `infra/istio/README.md`。

## mTLS 与网格范围

[peer-authentication.yaml](peer-authentication.yaml)：mesh 级 STRICT，**唯一一条策略、无任何
端口级例外**——注入范围内（micro-bl）没有需要网格外明文抓取的端口（业务指标走 OTLP push）；
中间件与可观测性整体不注入，它们的端口天然可达，不需要例外。

注入范围（[namespaces.yaml](../namespaces.yaml)）：

| 命名空间 | sidecar | 原因 |
|---|---|---|
| micro-bl | ✅ | 业务互调走自动 mTLS + L7 治理；到中间件的加密由应用层单向 TLS 承担 |
| middleware | ❌ | mysql/redis/kafka/minio 全部应用层单向 TLS，端到端覆盖 sidecar 管不到的路径；非 HTTP 协议从网格只拿到 L4 统计（exporter 已覆盖），注入只剩双重加密和抓取例外的成本 |
| observability | ❌ | Prometheus 要在网格外抓取，注入后对 K8s API 访问要额外 exclude |
| istio-system | chart 自管 | istiod / gateway |

## 后续补充

- `AuthorizationPolicy` 按服务账号限制调用关系（依赖各服务 ServiceAccount 命名规范先落地）。
  注意它只能约束**注入了 sidecar 的 Pod**——middleware 已退出网格，"谁能连 3306/9092"
  这一层身份控制不在 Istio 能力范围内，将来需要时用 Cilium NetworkPolicy（L3/L4）兜。
- 与 Cilium NetworkPolicy 的职责边界：Istio 管 L7 + 服务身份，Cilium 管 L3/L4 + 流量观测，
  同一意图不要写两遍。
- 资源预算：每个业务 Pod 注入 istio-proxy（requests 约 100m/128Mi 起），已计入 8C16G worker 的调度预算。
