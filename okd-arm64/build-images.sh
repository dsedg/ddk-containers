#!/bin/bash

set -exuo pipefail

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

OC=${OC:-oc}
SKOPEO=${SKOPEO:-skopeo}
PODMAN=${PODMAN:-podman}
BRANCH=${BRANCH:-release-4.17}
# Get the version from https://amd64.origin.releases.ci.openshift.org/
OKD_VERSION=${OKD_VERSION:-4.17.0-0.okd-scos-2024-12-03-010653}
CONTAINER_REG=${CONTAINER_REG:-quay.io/dsedg/okd-arm}

check_dependency() {
  if ! which ${OC}; then
     echo "You need to install oc from https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest/"
     exit 1
  fi
  if ! which ${SKOPEO}; then
     echo "you need to install skopeo https://github.com/containers/skopeo"
     exit 1
  fi
  if ! which ${PODMAN}; then
     echo "you need to install podman https://github.com/containers/podman"
     exit 1
  fi
}

login_to_registry() {
  podman login -u ${USERNAME} -p ${PASSWORD} quay.io
}

# Function to handle base-image repository
base_image() {
  local repo_url="https://github.com/openshift/images"
  local dockerfile_path="base/Dockerfile.rhel9"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Replace lines that begin with 'FROM registry.ci.openshift.org/ocp'
  sed -i 's|^FROM registry.ci.openshift.org/ocp/.*|FROM quay.io/centos/centos:stream9|' "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[base]}" -f "$dockerfile_path" .
  # Remove RT repo becaus there is no aarch64 for it 
  sed -i '/dnf config-manager/d' "$dockerfile_path"

  podman push "${images[base]}"

  cd ..
  rm -fr $repo
}

# Function to handle router-image repository
router_image() {
  local repo_url="https://github.com/openshift/router"
  local dockerfile_base_path="images/router/base/Dockerfile.rhel"
  local dockerfile_haproxy_path="images/router/haproxy/Dockerfile.rhel8"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply sed commands for both Dockerfiles in router repo
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_base_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_base_path"
  
  podman build --platform linux/arm64 -t "${images[haproxy-router-base]}" -f "$dockerfile_base_path" .
  podman push "${images[haproxy-router-base]}"
  
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*|FROM ${CONTAINER_REG}/haproxy-router-base:${OKD_VERSION}|" "$dockerfile_haproxy_path"
  sed -i "s|haproxy28|https://github.com/praveenkumar/minp/releases/download/v0.0.1/haproxy28-2.8.10-1.rhaos4.17.el9.aarch64.rpm|" "$dockerfile_haproxy_path"
  sed -i 's|yum install -y $INSTALL_PKGS|yum --disablerepo=rt install -y $INSTALL_PKGS|' "$dockerfile_haproxy_path"

  podman build --platform linux/arm64 -t "${images[haproxy-router]}" -f "$dockerfile_haproxy_path" .
  podman push "${images[haproxy-router]}"

  cd ..
  rm -fr $repo
}

# Function to handle kube-proxy repository
kube_proxy_image() {
  local repo_url="https://github.com/openshift/sdn"
  local dockerfile_path="images/kube-proxy/Dockerfile.rhel"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply sed commands for both Dockerfiles in router repo
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"
  sed -i 's|yum install -y --setopt=tsflags=nodocs $INSTALL_PKGS|yum --disablerepo=rt install -y --setopt=tsflags=nodocs $INSTALL_PKGS|' "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[kube-proxy]}" -f "$dockerfile_path" .
  podman push "${images[kube-proxy]}"

  cd ..
  rm -fr $repo
}


# Function to handle coredns-image repository
coredns_image() {
  local repo_url="https://github.com/openshift/coredns"
  local dockerfile_path="Dockerfile.openshift.rhel7"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the coredns Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[coredns]}" -f "$dockerfile_path" .
  podman push "${images[coredns]}"
  
  cd ..
  rm -fr $repo
}

# Function to handle csi-external-snapshotter-image repository
csi_external_snapshotter_image() {
  local repo_url="https://github.com/openshift/csi-external-snapshotter"
  local dockerfile_snapshot_controller_path="Dockerfile.snapshot-controller.openshift.rhel7"
  local dockerfile_webhook_path="Dockerfile.webhook.openshift.rhel7"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for both Dockerfiles
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_snapshot_controller_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_snapshot_controller_path"
  
  podman build --platform linux/arm64 -t "${images[csi-snapshot-controller]}" -f "$dockerfile_snapshot_controller_path" .
  podman push "${images[csi-snapshot-controller]}"
  
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_webhook_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_webhook_path"

  podman build --platform linux/arm64 -t "${images[csi-snapshot-validation-webhook]}" -f "$dockerfile_webhook_path" .
  podman push "${images[csi-snapshot-validation-webhook]}"

  cd ..
  rm -fr $repo
}

# Function to handle kube-rbac-proxy-image repository
kube_rbac_proxy_image() {
  local repo_url="https://github.com/openshift/kube-rbac-proxy"
  local dockerfile_path="Dockerfile.ocp"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the kube-rbac-proxy Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[kube-rbac-proxy]}" -f "$dockerfile_path" .
  podman push "${images[kube-rbac-proxy]}"
  
  cd ..
  rm -fr $repo
}


# Function to handle ovn-kubernetes-microshift-image repository
ovn_kubernetes_image() {
  local repo_url="https://github.com/openshift/ovn-kubernetes"
  local dockerfile_base_path="Dockerfile.base"
  local dockerfile_ovn_path="Dockerfile.microshift"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply sed commands for both Dockerfiles in router repo
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_base_path"
  sed -i 's|dnf install -y |dnf --disablerepo=rt install -y |' "$dockerfile_base_path"
  
  podman build --platform linux/arm64 -t "${images[ovn-kubernetes-base]}" -f "$dockerfile_base_path" .
  podman push "${images[ovn-kubernetes-base]}"
  
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_ovn_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*|FROM ${CONTAINER_REG}/ovn-kubernetes-base:${OKD_VERSION}|" "$dockerfile_ovn_path"

  podman build --platform linux/arm64 -t "${images[ovn-kubernetes-base]}" -f "$dockerfile_ovn_path" .
  podman push "${images[ovn-kubernetes-base]}"

  cd ..
  rm -fr $repo
}

# Function to handle containernetworking-plugins repository
containernetworking_plugins_microshift_image() {
  local repo_url="https://github.com/openshift/containernetworking-plugins"
  local dockerfile_path="Dockerfile.microshift"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the service-ca-operator Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.21-openshift-4.16 AS rhel9 |' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"
  sed -i 's|dnf install -y |dnf --disablerepo=rt install -y |' "$dockerfile_path"
  
  podman build --platform linux/arm64 -t "${images[containernetworking-plugins-microshift]}" -f "$dockerfile_path" .
  podman push "${images[containernetworking-plugins-microshift]}"

  cd ..
  rm -fr $repo
}
# Function to handle multus cni repository
multus_cni_microshift_image() {
  local repo_url="https://github.com/openshift/multus-cni"
  local dockerfile_path="Dockerfile.microshift"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the service-ca-operator Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.21-openshift-4.16 AS rhel9|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"
  sed -i 's|dnf install -y |dnf --disablerepo=rt install -y |' "$dockerfile_path"
  
  podman build --platform linux/arm64 -t "${images[multus-cni-microshift]}" -f "$dockerfile_path" .
  podman push "${images[multus-cni-microshift]}"

  cd ..
  rm -fr $repo
}
# Function to handle pod-image repository
pod_image() {
  local repo_url="https://github.com/openshift/kubernetes"
  local dockerfile_path="build/pause/Dockerfile.Rhel"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the pod Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"

  pushd build/pause && podman build --platform linux/arm64 -t "${images[pod]}" -f $(basename "$dockerfile_path") . &&  popd
  podman push "${images[pod]}"

  cd ..
  rm -fr $repo
}

# Function to handle cli-image repository
cli_image() {
  local repo_url="https://github.com/openshift/oc"
  local dockerfile_path="images/cli/Dockerfile.rhel"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the cli Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[cli]}" -f "$dockerfile_path" .
  podman push "${images[cli]}"

  cd ..
  rm -fr $repo
}

# Function to handle service-ca-operator-image repository
service_ca_operator_image() {
  local repo_url="https://github.com/openshift/service-ca-operator"
  local dockerfile_path="Dockerfile.rhel7"
  local repo=$(basename ${repo_url})

  git clone --branch "$BRANCH" --single-branch "$repo_url"
  cd $repo || { echo "Failed to access repo directory"; return 1; }

  # Apply the sed commands for the service-ca-operator Dockerfile
  sed -i 's|^FROM registry.ci.openshift.org/ocp/builder.*|FROM registry.ci.openshift.org/openshift/release:rhel-9-release-golang-1.22-openshift-4.17 AS builder|' "$dockerfile_path"
  sed -i "s|^FROM registry.ci.openshift.org/ocp/.*:base-rhel9|FROM ${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9|" "$dockerfile_path"

  podman build --platform linux/arm64 -t "${images[service-ca-operator]}" -f "$dockerfile_path" .
  podman push "${images[service-ca-operator]}"

  cd ..
  rm -fr $repo
}

# Use image sha256 instead tags
update_image_tag_to_sha() {
    for key in "${!images[@]}"; do
      image_with_sha_hash=$(skopeo inspect --format "{{.Name}}@{{.Digest}}" docker://"${images[$key]}")
      images[$key]=${image_with_sha_hash}
    done
}

# Create a new release of okd using oc
create_new_okd_release() {
    oc adm release new --from-release registry.ci.openshift.org/origin/release-scos:scos-4.17 \
       --keep-manifest-list \
        cli="${images[cli]}" \
	haproxy-router="${images[haproxy-router]}" \
	kube-proxy="${images[kube-proxy]}" \
	coredns="${images[coredns]}" \
        csi-snapshot-controller="${images[csi-snapshot-controller]}" \
        csi-snapshot-validation-webhook="${images[csi-snapshot-validation-webhook]}" \
	kube-rbac-proxy="${images[kube-rbac-proxy]}" \
	pod="${images[pod]}" \
	service-ca-operator="${images[service-ca-operator]}" \
        containernetworking-plugins-microshift="${images[containernetworking-plugins-microshift]}" \
	ovn-kubernetes-microshift="${images[ovn-kubernetes-microshift]}" \
        multus-cni-microshift="${images[multus-cni-microshift]}" \
	--to-image ${CONTAINER_REG}/okd-arm-release:${OKD_VERSION}
}

# Main function to run all the image update functions
update_images() {
  base_image
  router_image
  kube_proxy_image
  coredns_image
  csi_external_snapshotter_image
  kube_rbac_proxy_image
  pod_image
  cli_image
  service_ca_operator_image
  ovn_kubernetes_image
  containernetworking_plugins_microshift_image
  multus_cni_microshift_image
}

# Declare an associative array
declare -A images

# Populate the array with key-value pairs
images=(
    [base]="${CONTAINER_REG}/scos-${OKD_VERSION}:base-stream9"
    [cli]="${CONTAINER_REG}/cli:${OKD_VERSION}"
    [haproxy-router-base]="${CONTAINER_REG}/haproxy-router-base:${OKD_VERSION}"
    [haproxy-router]="${CONTAINER_REG}/haproxy-router:${OKD_VERSION}"
    [kube-proxy]="${CONTAINER_REG}/kube-proxy:${OKD_VERSION}"
    [coredns]="${CONTAINER_REG}/coredns:${OKD_VERSION}"
    [csi-snapshot-controller]="${CONTAINER_REG}/csi-snapshot-controller:${OKD_VERSION}"
    [csi-snapshot-validation-webhook]="${CONTAINER_REG}/csi-snapshot-validation-webhook:${OKD_VERSION}"
    [kube-rbac-proxy]="${CONTAINER_REG}/kube-rbac-proxy:${OKD_VERSION}"
    [pod]="${CONTAINER_REG}/pod:${OKD_VERSION}"
    [service-ca-operator]="${CONTAINER_REG}/service-ca-operator:${OKD_VERSION}"
    [ovn-kubernetes-microshift]="${CONTAINER_REG}/ovn-kubernetes-microshift:${OKD_VERSION}"
    [ovn-kubernetes-base]="${CONTAINER_REG}/ovn-kubernetes-base:${OKD_VERSION}"
    [containernetworking-plugins-microshift]="${CONTAINER_REG}/containernetworking-plugins-microshift:${OKD_VERSION}"
    [multus-cni-microshift]="${CONTAINER_REG}/multus-cni-microshift:${OKD_VERSION}"
)

# check the install process
check_dependency
#login_to_registry

# check if image already exist
if skopeo inspect --format "Digest: {{.Digest}}" docker://${CONTAINER_REG}/okd-arm-release:${OKD_VERSION}; then
   echo "image ${CONTAINER_REG}/okd-arm-release:${OKD_VERSION} already exist"
   exit 0
fi

# Run the update process
update_images
update_image_tag_to_sha
create_new_okd_release
