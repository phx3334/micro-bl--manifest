# Cilium

当前 Demo 方案：Cilium 作为 CNI，开启 Hubble；初期保留 kube-proxy，稳定后再切换 `kubeProxyReplacement`（切换三步见 values.yaml 注释）。

配置拆两个文件：`values.yaml`（环境无关基线：ipam / 分阶段开关 / Hubble / 资源）、`values-prod.yaml`（仅资源差异）。

```bash
helm repo add cilium https://helm.cilium.io/
helm upgrade --install cilium cilium/cilium -n kube-system \
  --version 1.18.5 \
  -f values.yaml -f values-prod.yaml
```

验证：

```bash
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=cilium
```

后续补充：
- NetworkPolicy 基线：默认拒绝、按命名空间放行。middleware 退出 Istio 网格后这条
  基线的价值上升——「谁能连 3306/6379/9092」不再有 AuthorizationPolicy 可表达，
  L3/L4 收口只能靠这里（见 infra/base/istio/README.md 的职责边界说明）。
- `kubeProxyReplacement=true` 切换与回滚步骤。
- Hubble 流量观测与告警。