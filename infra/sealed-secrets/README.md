# Sealed Secrets

把 Kubernetes Secret 加密后放进 Git：**任何人都能加密，只有目标集群的控制器能解密**。

## 安装（bootstrap 阶段）

```bash
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets-controller sealed-secrets/sealed-secrets \
  -n kube-system --version 2.22.0 -f values.yaml

kubectl -n kube-system rollout status deploy/sealed-secrets-controller
```

顺序要求：控制器必须先于 `infra/credentials/` 里的 SealedSecret 就绪，否则再同步会报
`no matches for kind "SealedSecret"`。

## 备份解封密钥（必做）

控制器首次启动会生成密钥对，存于 `kube-system` 的 Secret：

```bash
kubectl -n kube-system get secret \
  -l sealedsecrets.bitnami.com/sealed-secrets-key=active -o yaml \
  > sealed-secrets-key.backup.yaml     # 存到密码管理器/离线介质，绝不提交仓库
```

恢复顺序：**先 apply 这个备份 Secret，再安装控制器**。顺序反了控制器会生成新密钥，
旧 SealedSecret 全部解不开（且不可恢复）。

## kubeseal 客户端

从 <https://github.com/bitnami/sealed-secrets/releases/tag/v0.41.2> 下载对应平台的
`kubeseal` 二进制（项目已迁到 `bitnami/sealed-secrets`）。用法见
[../credentials/README.md](../credentials/README.md)。

## 定位

- 它属于**平台安全基座**，和 cert-manager 同级，由 ansible/手工在 bootstrap 阶段安装；
- 不交给 ArgoCD 自管：它必须先于 ArgoCD 里的 SealedSecret 存在（同类于 cert-manager）。
