terraform {
  required_version = ">= 1.6.0"

  required_providers {
    alicloud = {
      source = "aliyun/alicloud"
      # 钉在 1.x 最后一个稳定版；2.x 是上游重写，待验证后再升级
      version = "1.294.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "2.5.2"
    }
  }

  # 状态默认保存在本地（已被 project-infra/.gitignore 排除）。
  # 多人协作时换成 OSS 后端，并先创建 bucket：
  # backend "oss" {
  #   bucket = "micro-bl-tfstate"
  #   key    = "k8s/terraform.tfstate"
  #   region = "cn-hangzhou"
  # }
}
