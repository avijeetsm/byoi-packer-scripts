// Delta recipe: Install Tailscale and Java 25 on an existing base image.
// BYOI supplies the googlecompute source/build block.
// This file intentionally contains only variables and provisioners.

provisioner "shell" {
  environment_vars = ["DEBIAN_FRONTEND=noninteractive"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts = [
    "${path.root}/scripts/install-tailscale.sh",
    "${path.root}/scripts/install-java.sh"
  ]
}
