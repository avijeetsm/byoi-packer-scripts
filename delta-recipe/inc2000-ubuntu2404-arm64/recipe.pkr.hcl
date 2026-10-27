// Delta recipe: INC-2000 (eMudhra/emSign root CAs, CVE-2026-111943) and the related security updates
// (php2shell, Go, Ruby, Node, Python) on an existing Harness Ubuntu 24.04 arm64 image.
// BYOI supplies the googlecompute source/build block.
// This file intentionally contains only provisioners.
//
// Every script is re-runnable and exits non-zero when a check fails, which stops the build, so no
// image is created unless all fixes pass their checks.
// Order matters: fix-python.sh reuses the pip wheel bundled with the Python 3.13 that fix-emudhra.sh
// installs, and image-cleanup.sh must run last.
// scripts/verify.sh is not part of the build: run it on a VM booted from the new image.

provisioner "shell" {
  environment_vars = ["DEBIAN_FRONTEND=noninteractive", "REMOVE_OLD=1"]
  execute_command  = "sudo sh -c '{{ .Vars }} {{ .Path }}'"
  scripts = [
    "${path.root}/scripts/fix-emudhra.sh",
    "${path.root}/scripts/fix-python.sh",
    "${path.root}/scripts/fix-php.sh",
    "${path.root}/scripts/fix-go.sh",
    "${path.root}/scripts/fix-ruby.sh",
    "${path.root}/scripts/image-cleanup.sh"
  ]
}
