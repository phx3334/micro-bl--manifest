# Harbor

安装、证书链路、NodePort 和组件资源见 [values.yaml](values.yaml) 顶部注释。本文件只记录 chart 不管、但生产必须配的两件事：**缓存镜像的体积治理**和**保留策略**。

## 缓存镜像

Tekton 的 `build-scan-push` 用 BuildKit registry cache，缓存镜像有两个：

| 仓库 | 用途 |
|---|---|
| `micro-bl/buildcache-go:main` | 4 个 Go 服务共用的 builder 层缓存（Go 工具链、模块层） |
| `micro-bl/buildcache-web:main` | 前端 npm 依赖与构建层缓存 |

`--export-cache mode=max` 会把 builder 阶段的中间层一起导出，所以缓存镜像会随依赖增长，必须有配额和清理策略。

## 保留策略（关键）

**不要对 `buildcache-*` 应用“保留最近 N 个 tag”的规则**：缓存只用一个固定 tag（`main`），按 tag 数量清理会把唯一的缓存删掉。

| 方案 | 做法 |
|---|---|
| 当前（同项目） | retention 规则的 repository 选择器**只选业务仓库**（`micro-bl-*`），不要用 `**`；业务镜像保留最近 30 个 tag，缓存仓库不在规则范围内 |
| 生产推荐（独立项目） | 新建 `micro-bl-cache` 项目放缓存镜像；项目级 quota 限制 10GiB，不配 tag 保留规则；robot 同时需要 `micro-bl` 和 `micro-bl-cache` 的 push 权限 |

同项目方案下，只要 retention 不匹配 `buildcache-*`，缓存就不会被定时任务误删。

## 配额

Harbor 项目配额（UI：Project → Configuration → Quota）：

- `micro-bl`：业务镜像按版本数量估算，20GiB 起步；
- 缓存仓库：10GiB 起步。超过配额后 cache push 会失败，但 `ignore-error=true` 保证只降级为无缓存构建，不阻断流水线。

## 监控

Harbor 暴露项目配额相关指标，建议加一条容量告警（指标名以实际 `/metrics` 为准，接入前先核对）：

```promql
harbor_project_quota_usage_byte / harbor_project_quota_hard_byte > 0.8
```

## 清理

缓存可以随时删除，下一次构建会重新生成；**不要在构建进行中删**，否则 export cache 会失败（同样是 `ignore-error` 兜底）。

UI 里删 artifact，或：

```bash
curl -u admin:<password> -X DELETE \
  "https://<harbor>/api/v2.0/projects/micro-bl/repositories/buildcache-go/artifacts/main"
```

## 分支策略

当前 cache tag 固定为 `main`，因为只有 main 触发构建。将来如果 PR 也构建，按分支拆 ref：

- `buildcache-go:pr-<number>`
- 合并后清理该分支的 cache，避免无限增长。

## 相关文件

- [values.yaml](values.yaml)：Harbor 安装基线
- [../tekton/tasks/build-scan-push.yaml](../tekton/tasks/build-scan-push.yaml)：cache ref 的使用方
- [../tekton/pipelines/build-app.yaml](../tekton/pipelines/build-app.yaml)：Go / web 缓存 ref 的分配
