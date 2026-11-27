resource "alicloud_key_pair" "this" {
  key_pair_name = var.key_pair_name
  public_key    = var.ssh_public_key
}

# 控制面：2C4G（ecs.c7.large），无数据盘（etcd 与 apiserver 写系统盘 ESSD）
resource "alicloud_instance" "master" {
  count = var.master_count

  instance_name        = "${local.name_prefix}-master-${count.index + 1}"
  host_name            = "k8s-master-${count.index + 1}"
  image_id             = data.alicloud_images.ubuntu.images[0].id
  instance_type        = var.master_instance_type
  vswitch_id           = alicloud_vswitch.this.id
  security_groups      = [alicloud_security_group.this.id]
  private_ip           = local.master_private_ips[count.index]
  key_name             = alicloud_key_pair.this.key_pair_name
  instance_charge_type = "PostPaid"

  # 公网：按流量计费，带宽上限只作为突发上限，不按带宽预付费。
  # 所有节点都有自动公网 IP 供 Ansible 按主机 SSH；对外服务入口是固定 EIP
  # （绑定 apiserver SLB，见 eip.tf），与实例公网 IP 无关。
  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out

  system_disk_category = "cloud_essd"
  system_disk_size     = var.master_system_disk_size

  tags = merge(local.common_tags, { role = "control-plane" })
}

# 工作节点：8C16G + 80G ESSD 数据盘（variable worker_data_disk_size）。
# 数据盘单独挂载（ansible 负责格式化与挂载点），PVC 的云盘与本地盘规划见 README/交付说明。
resource "alicloud_instance" "worker" {
  count = var.worker_count

  instance_name        = "${local.name_prefix}-worker-${count.index + 1}"
  host_name            = "k8s-worker-${count.index + 1}"
  image_id             = data.alicloud_images.ubuntu.images[0].id
  instance_type        = var.worker_instance_type
  vswitch_id           = alicloud_vswitch.this.id
  security_groups      = [alicloud_security_group.this.id]
  private_ip           = local.worker_private_ips[count.index]
  key_name             = alicloud_key_pair.this.key_pair_name
  instance_charge_type = "PostPaid"
  # CSI Controller/Node 通过实例 RAM 角色访问 ECS OpenAPI，不在集群里放 AK；
  # 实例与角色的绑定见 ram.tf 的 alicloud_ecs_ram_role_attachment（role_name 字段已弃用）

  internet_charge_type       = "PayByTraffic"
  internet_max_bandwidth_out = var.internet_max_bandwidth_out

  system_disk_category = "cloud_essd"
  system_disk_size     = var.worker_system_disk_size

  data_disks {
    name                 = "${local.name_prefix}-data-${count.index + 1}"
    size                 = var.worker_data_disk_size
    category             = "cloud_essd"
    encrypted            = true
    delete_with_instance = true
  }

  tags = merge(local.common_tags, { role = "worker" })
}
