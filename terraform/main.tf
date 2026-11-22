provider "alicloud" {
  region = var.region
}

locals {
  name_prefix = "micro-bl"
  az          = var.availability_zone != "" ? var.availability_zone : data.alicloud_zones.this.zones[0].id

  # 固定私网 IP，避免 kubeadm 配置随实例重建而变化：master 10 起、worker 20 起
  # 控制面入口是 CLB（见 slb.tf），不再占用交换机内的 VIP
  master_private_ips = [for i in range(var.master_count) : cidrhost(var.vswitch_cidr, 10 + i)]
  worker_private_ips = [for i in range(var.worker_count) : cidrhost(var.vswitch_cidr, 20 + i)]

  common_tags = merge(var.tags, { managed-by = "terraform" })
}

# 同可用区选型：以 worker 规格 + ESSD 为过滤条件，masters/workers 都落在本地盘可用的区
data "alicloud_zones" "this" {
  available_instance_type     = var.worker_instance_type
  available_disk_category     = "cloud_essd"
  available_resource_creation = "VSwitch"
}

data "alicloud_images" "ubuntu" {
  owners      = "system"
  name_regex  = var.image_name_regex
  most_recent = true
}
