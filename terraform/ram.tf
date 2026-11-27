# 阿里云云盘 CSI 专用 RAM 角色。
# CSI Controller 运行在 worker 上，通过 ECS 实例元数据获取 STS，不需要在集群里放 AccessKey。
resource "alicloud_ram_role" "csi" {
  role_name   = "${local.name_prefix}-csi"
  description = "RAM role for Alibaba Cloud CSI disk driver on ${local.name_prefix} workers"

  assume_role_policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect = "Allow"
      Action = "sts:AssumeRole"
      Principal = {
        Service = ["ecs.aliyuncs.com"]
      }
    }]
  })

  force = true
}

resource "alicloud_ram_policy" "csi" {
  policy_name = "${local.name_prefix}-csi-disk"
  description = "Allow CSI to create/attach/detach/delete cloud disks"

  policy_document = jsonencode({
    Version = "1"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ecs:CreateDisk",
        "ecs:DeleteDisk",
        "ecs:AttachDisk",
        "ecs:DetachDisk",
        "ecs:DescribeDisks",
        "ecs:ModifyDiskAttribute",
        "ecs:ResizeDisk",
        "ecs:ModifyDiskSpec",
        "ecs:DescribeInstances",
        "ecs:DescribeInstanceAttribute",
        "ecs:DescribeInstanceTypes",
        "ecs:DescribeRegions",
        "ecs:DescribeZones",
        "ecs:DescribeAvailableResource"
      ]
      Resource = "*"
    }]
  })

  force = true
}

resource "alicloud_ram_role_policy_attachment" "csi" {
  policy_name = alicloud_ram_policy.csi.policy_name
  role_name   = alicloud_ram_role.csi.role_name
  policy_type = "Custom"
}

# worker 实例绑定 CSI RAM 角色（替代 alicloud_instance 上已弃用的 role_name 字段）。
# CSI Controller/Node 通过实例元数据获取 STS，不需要在集群里放 AccessKey。
# 用 count 而非 for_each：实例 ID 在 apply 时才可知，for_each 的键必须静态确定。
resource "alicloud_ecs_ram_role_attachment" "csi" {
  count = var.worker_count

  instance_id   = alicloud_instance.worker[count.index].id
  ram_role_name = alicloud_ram_role.csi.role_name
}
