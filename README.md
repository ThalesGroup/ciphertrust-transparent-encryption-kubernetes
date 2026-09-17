# CTE for Kubernetes deployment files

Deployment files for CipherTrust Transparent Encryption for Kubernetes.

# About CTE for Kubernetes

Product Description:

[https://cpl.thalesgroup.com/encryption/ciphertrust-transparent-data-encryption-kubernetes](https://cpl.thalesgroup.com/encryption/ciphertrust-transparent-data-encryption-kubernetes)

More information can be found through Thales online documentation portal at:

[https://thalesdocs.com/ctp/cte-con/cte-k8s/latest/](https://thalesdocs.com/ctp/cte-con/cte-k8s/latest/)

# Quick installation guide
> **_NOTE:_**  Refer to the online docs for a detailed installation and configuration guide.

Install CTE for Kubernetes through the YAML files available in the
ciphertrust-transparent-encryption-kubernetes Git repository at:

`git clone https://github.com/thalescpl-io/ciphertrust-transparent-encryption-kubernetes.git`

The CTE for Kubernetes images are distributed though Docker Hub in the following
URL:

[https://hub.docker.com/r/thalesciphertrust/ciphertrust-transparent-encryption-kubernetes](https://hub.docker.com/r/thalesciphertrust/ciphertrust-transparent-encryption-kubernetes)

## Options for deploy.sh

|Option| Function| Description|
|------|---------|------------|
|-i, \--image=| Custom image repository/name | Format: registry.com/repo/image-name |
|-t, \--tag=| Tag of image on the server | Default: 2.0.0-latest (from values.yaml) |
|\--deploy-mode=| Deployment mode: csi, cos, or both | Default: both |
|-r, \--remove| Remove all the running pods, services and secrets | - |
|-o, \--operator| Deploy CTE-K8s Operator and CSI driver | Works with --image flag |
|\--operator-ns=| Namespace for Operator deployment | Used with --operator |
|\--cte-ns=| Namespace for CSI driver deployment | Used with --operator |
|\--cri-sock=| Container Runtime Interface socket path | Auto-detected if not specified |
|\--helm| Deploy using Helm (default unless --operator specified) | - |
|-h, \--help| Display help message | - |

## Deployment Modes

The deploy.sh script now supports three deployment modes for the 2.0.0 release:

### Both CSI and COS (default)
Deploy both the CSI driver and COS controller:

```bash
./deploy.sh
```

Or explicitly:

```bash
./deploy.sh --deploy-mode both
```

### CSI Driver Only
Deploy only the CSI driver:

```bash
./deploy.sh --deploy-mode csi
```

### COS Controller Only
Deploy only the COS (Cloud Object Storage) controller:

```bash
./deploy.sh --deploy-mode cos
```

## Deploy CTE for Kubernetes

Deploy both services using the following command:

```bash
./deploy.sh
```

Deploy CSI driver only:

```bash
./deploy.sh --deploy-mode csi
```

Deploy COS controller only:

```bash
./deploy.sh --deploy-mode cos
```

With custom image tag:

```bash
./deploy.sh --tag 2.0.0-latest --deploy-mode both
```

## Using Custom Image Registry

You can deploy using images from a custom or private container registry using the `--image` flag:

```bash
# Use custom registry with default tag
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s

# Use custom registry with custom tag
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s --tag=2.0.0-latest

# Use custom registry with authentication
./deploy.sh --helm \
  --image=private-registry.company.com/security/cte-k8s \
  --tag=2.0.0-latest \
  --server=private-registry.company.com \
  --user=registry-user \
  --passwd='registry-password'

# Deploy only CSI with custom image
./deploy.sh --helm --image=harbor.company.com/security/cte-k8s --deploy-mode=csi
```

The image format should be: `registry.com/repository/image-name`

**Common use cases:**
- Using a private container registry
- Using a mirrored/cached image repository for air-gapped environments
- Testing custom builds in non-production environments

## Uninstalling CTE for Kubernetes

Stop any pods that are using CTE-CSI volumes and run:

```bash
./deploy.sh --remove
```

This will remove all deployed services based on the current deployment mode.
