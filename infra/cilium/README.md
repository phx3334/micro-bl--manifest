# Cilium

当前方案：Cilium 作为 CNI + **eBPF 完全替代 kube-proxy**（`kubeProxyReplacement: true`），开启 Hubble。
配套：kubeadm init 跳过 `addon/kube-proxy`（见 `ansible/roles/kubeadm_master/tasks/main.yml`），
集群中不存在 kube-proxy DaemonSet，Service 转发（ClusterIP/NodePort）全由 Cilium eBPF 处理。
回滚：values.yaml 改回 `false`、去掉 kubeadm 的 `--skip-phases` 后重建集群（两者不能同时开）。

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
- Hubble 流量观测与告警。