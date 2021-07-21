#!/usr/bin/env bash

set -eo pipefail

kindVersion=$(kind version);
K8S_VERSION=${k8sVersion:-v1.21.1@sha256:fae9a58f17f18f06aeac9772ca8b5ac680ebbed985e266f711d936e91d113bad}
CLUSTER_NAME=${KIND_CLUSTER_NAME:-knative}
KIND_VERSION=${KIND_VERSION:-v0.11}

echo "KinD version is ${kindVersion}"
if [[ ! $kindVersion =~ "${KIND_VERSION}." ]]; then
  echo "WARNING: Please make sure you are using KinD version ${KIND_VERSION}.x, download from https://github.com/kubernetes-sigs/kind/releases"
  echo "For example if using brew, run: brew upgrade kind"
  read -p "Do you want to continue on your own risk? Y/n: " REPLYKIND </dev/tty
  if [ "$REPLYKIND" == "Y" ] || [ "$REPLYKIND" == "y" ] || [ -z "$REPLYKIND" ]; then
    echo "You are very brave..."
    sleep 2
  elif [ "$REPLYKIND" == "N" ] || [ "$REPLYKIND" == "n" ]; then
    echo "Installation stopped, please upgrade kind and run again"
    exit 0
  fi
fi

REPLY=continue
KIND_EXIST="$(kind get clusters -q | grep ${CLUSTER_NAME} || true)"
if [[ ${KIND_EXIST} ]] ; then
 read -p "Knative Cluster kind-${CLUSTER_NAME} already installed, delete and re-create? N/y: " REPLY </dev/tty
fi
if [ "$REPLY" == "Y" ] || [ "$REPLY" == "y" ]; then
  kind delete cluster --name ${CLUSTER_NAME}
elif [ "$REPLY" == "N" ] || [ "$REPLY" == "n" ] || [ -z "$REPLY" ]; then
  echo "Installation skipped"
  exit 0
fi

# Create registry container unless it already exists
# https://kind.sigs.k8s.io/docs/user/local-registry/#create-a-cluster-and-registry
reg_name='node-registry'
reg_port='5000'
running="$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)"
if [ "${running}" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --name "${reg_name}" registry:2
fi

KIND_CLUSTER=$(mktemp)
cat <<EOF | kind create cluster --name ${CLUSTER_NAME} --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  image: kindest/node:${K8S_VERSION}
containerdConfigPatches:
- |-
  [plugins."io.containerd.grpc.v1.cri".registry.mirrors."node-registry:${reg_port}"]
    endpoint = ["http://${reg_name}:${reg_port}"]
    [plugins."io.containerd.grpc.v1.cri".registry.configs."node-registry:${reg_port}".tls]
      insecure_skip_verify = true
EOF
echo "Waiting on cluster to be ready..."
sleep 10
kubectl wait pod --timeout=-1s --for=condition=Ready -l '!job-name' -n kube-system > /dev/null

# Connect the registry to the cluster network (the network may already be connected)
# https://kind.sigs.k8s.io/docs/user/local-registry/#create-a-cluster-and-registry
docker network connect 'kind' "${reg_name}" || true

# Document the local registry
# https://github.com/kubernetes/enhancements/tree/master/keps/sig-cluster-lifecycle/generic/1755-communicating-a-local-registry
# https://kind.sigs.k8s.io/docs/user/local-registry/#create-a-cluster-and-registry
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "node-registry:${reg_port}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
