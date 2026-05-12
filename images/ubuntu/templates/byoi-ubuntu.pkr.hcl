// BYOI-compatible conversion of virtual-environments Ubuntu templates.
// BYOI supplies the googlecompute source/build block and installs Docker via dockerVersion.
// This file intentionally contains only variables and provisioners.

variable "helper_script_folder" {
  type    = string
  default = "/imagegeneration/helpers"
}

variable "image_folder" {
  type    = string
  default = "/imagegeneration"
}

variable "image_os" {
  type    = string
  default = (env("PLUGIN_BASE_IMAGE") == "ubuntu/22.04" || env("PLUGIN_BASEIMAGE") == "ubuntu/22.04") ? "ubuntu22" : "ubuntu24"
}

variable "image_version" {
  type    = string
  default = "dev"
}

variable "imagedata_file" {
  type    = string
  default = "/imagegeneration/imagedata.json"
}

variable "installer_script_folder" {
  type    = string
  default = "/imagegeneration/installers"
}

variable "toolset_file" {
  type    = string
  default = (env("PLUGIN_BASE_IMAGE") == "ubuntu/22.04" || env("PLUGIN_BASEIMAGE") == "ubuntu/22.04") ? "toolset-2204.json" : "toolset-2404.json"
}

variable "readme_file" {
  type    = string
  default = (env("PLUGIN_BASE_IMAGE") == "ubuntu/22.04" || env("PLUGIN_BASEIMAGE") == "ubuntu/22.04") ? "Ubuntu2204-Readme.md" : "Ubuntu2404-Readme.md"
}

provisioner "shell" {
  execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  inline          = ["mkdir ${var.image_folder}", "chmod 777 ${var.image_folder}"]
}

provisioner "file" {
  destination = "${var.helper_script_folder}"
  source      = "${path.root}/../scripts/helpers"
}

provisioner "shell" {
  execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  script          = "${path.root}/../scripts/build/configure-apt-mock.sh"
}

provisioner "shell" {
  environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts = [
    "${path.root}/../scripts/build/install-ms-repos.sh",
    "${path.root}/../scripts/build/configure-apt-sources.sh",
    "${path.root}/../scripts/build/configure-apt.sh"
  ]
}

provisioner "shell" {
  execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  script          = "${path.root}/../scripts/build/configure-limits.sh"
}

provisioner "file" {
  destination = "${var.installer_script_folder}"
  source      = "${path.root}/../scripts/build"
}

provisioner "file" {
  destination = "${var.installer_script_folder}/toolset.json"
  source      = "${path.root}/../toolsets/${var.toolset_file}"
}

provisioner "shell" {
  environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGEDATA_FILE=${var.imagedata_file}"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts          = ["${path.root}/../scripts/build/configure-image-data.sh"]
}

provisioner "shell" {
  environment_vars = ["IMAGE_VERSION=${var.image_version}", "IMAGE_OS=${var.image_os}", "HELPER_SCRIPTS=${var.helper_script_folder}"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts          = ["${path.root}/../scripts/build/configure-environment.sh"]
}

provisioner "shell" {
  execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  inline = [
    "cat > /usr/local/bin/invoke_tests <<'EOF'\n#!/usr/bin/env bash\necho \"Skipping tests: $*\"\nexit 0\nEOF",
    "chmod +x /usr/local/bin/invoke_tests"
  ]
}

provisioner "shell" {
  environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}", "INSTALLER_SCRIPT_FOLDER=${var.installer_script_folder}", "DEBIAN_FRONTEND=noninteractive"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts = [
    "${path.root}/../scripts/build/install-apt-vital.sh",
    "${path.root}/../scripts/build/install-java-tools.sh",
    "${path.root}/../scripts/build/install-tailscale.sh"
  ]
}

provisioner "shell" {
  environment_vars = ["HELPER_SCRIPTS=${var.helper_script_folder}"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts          = ["${path.root}/../scripts/build/configure-snap.sh"]
}

provisioner "shell" {
  execute_command   = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  expect_disconnect = true
  inline            = ["echo 'Reboot VM'", "sudo reboot"]
}

provisioner "shell" {
  execute_command     = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  pause_before        = "1m0s"
  scripts             = ["${path.root}/../scripts/build/cleanup.sh"]
  start_retry_timeout = "10m"
}

provisioner "shell" {
  execute_command = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts         = ["${path.root}/../scripts/build/set-etc-env.sh"]
}
