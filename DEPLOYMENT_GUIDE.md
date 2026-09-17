# CTE Kubernetes 2.0.0 Deployment Guide

Quick reference for deploying CSI driver, COS controller, or both.

## Quick Start

### Default: Deploy Both CSI and COS
```bash
cd deploy
./deploy.sh
```

### CSI Driver Only
```bash
./deploy.sh --deploy-mode csi
```

### COS Controller Only
```bash
./deploy.sh --deploy-mode cos
```

## Common Deployment Scenarios

### Scenario 1: Deploy with Custom Image Tag
```bash
./deploy.sh --tag 2.0.0-latest --deploy-mode both
```

### Scenario 2: Deploy with Custom Image Repository
```bash
# Use custom registry with default tag
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s

# Use custom registry with custom tag
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s --tag=2.0.0-latest

# Combined with deployment modes
./deploy.sh --helm --image=harbor.company.com/security/cte-k8s --deploy-mode=csi
```

### Scenario 3: Deploy from Private Registry with Authentication
```bash
# With credentials for image pull
./deploy.sh --helm \
  --image=private-registry.company.com/security/cte-k8s \
  --tag=2.0.0-latest \
  --server=private-registry.company.com \
  --user=registry-user \
  --passwd='registry-password'
```

**Note:** When `--server`, `--user`, and `--passwd` are provided, an image pull secret will be created automatically.

### Scenario 4: Deploy CSI with Custom CRI Socket
For containerd:
```bash
./deploy.sh --deploy-mode csi --cri-sock /run/containerd/containerd.sock
```

For CRI-O:
```bash
./deploy.sh --deploy-mode csi --cri-sock /run/crio/crio.sock
```

For Docker:
```bash
./deploy.sh --deploy-mode csi --cri-sock /run/cri-dockerd.sock
```

### Scenario 5: Upgrade Existing Installation
```bash
# To add COS to existing CSI deployment
./deploy.sh --deploy-mode both --tag 2.0.0

# To upgrade both services
./deploy.sh --tag 2.0.0 --deploy-mode both
```

### Scenario 6: Switch Deployment Mode
```bash
# If CSI+COS is deployed and you want CSI only
./deploy.sh --deploy-mode csi

# If CSI is deployed and you want to add COS
./deploy.sh --deploy-mode both
```

## Verification

### Verify CSI Deployment
```bash
# Check if CSI driver is installed
kubectl get csidriver

# Check CSI controller pod
kubectl get pods -n kube-system -l app=cte-csi-controller

# Check CSI node pods
kubectl get pods -n kube-system -l app=cte-csi-node
```

### Verify COS Deployment
```bash
# Check if CRD is installed
kubectl get crd cmregistrationclasses.thalesgroup.com

# Check COS controller pod
kubectl get pods -n kube-system -l app.kubernetes.io/name=cte-cos

# Check created custom resources
kubectl get cmregistrationclass -A
```

### Verify Both Services
```bash
# Check all CTE resources
kubectl get all -n kube-system | grep cte

# Check secrets
kubectl get secrets -n kube-system | grep cte-csi-secret

# Check RBAC
kubectl get clusterrole | grep cte
kubectl get clusterrolebinding | grep cte
```

## Removal

### Remove All Services
```bash
./deploy.sh --remove
```

### Remove CSI Only
```bash
./deploy.sh --remove --deploy-mode csi
```

### Remove COS Only
```bash
./deploy.sh --remove --deploy-mode cos
```

## Troubleshooting

### Check Deployment Status
```bash
# Watch CSI deployment
kubectl logs -n kube-system -l app=cte-csi-controller -f

# Watch COS deployment
kubectl logs -n kube-system -l app.kubernetes.io/name=cte-cos -f
```

### Verify Image Pull
```bash
# Check image pull secret exists
kubectl get secret cte-csi-secret -n kube-system

# Check pod events for image pull errors
kubectl describe pod <pod-name> -n kube-system
```

### Check RBAC Permissions
```bash
# Verify service accounts exist
kubectl get sa -n kube-system | grep cte

# Verify cluster roles exist
kubectl get clusterrole | grep cte

# Verify cluster role bindings exist
kubectl get clusterrolebinding | grep cte
```

## Configuration Options

### Image Configuration

**Method 1: Use the --image flag (Recommended)**
```bash
# Override image repository
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s

# Override both image and tag
./deploy.sh --helm --image=myregistry.io/myteam/cte-k8s --tag=2.0.0-latest
```

**Method 2: Edit values.yaml**
Edit `deploy/kubernetes/2.0.0/values.yaml`:
```yaml
image:
  cteCsiImage: "docker.io/thalesciphertrust/ciphertrust-transparent-encryption-kubernetes"
  cteCsiTag: "2.0.0-latest"
  pullPolicy: Always
```

**Method 3: Use EXTRA_OPTIONS environment variable**
```bash
export EXTRA_OPTIONS="--set image.cteCsiImage=custom-registry.io/cte --set image.cteCsiTag=2.0.0"
./deploy.sh --helm
```

### CSI Configuration
Enable/disable CSI and set CRI socket:
```bash
./deploy.sh \
  --set csi.enabled=true \
  --set csi.CRISocket=/run/containerd/containerd.sock
```

### COS Configuration
Enable/disable COS and set replicas:
```bash
./deploy.sh \
  --set cos.enabled=true \
  --set cos.replicaCount=3
```

### Namespace Configuration
Deploy to custom namespace:
```bash
# Edit values.yaml and change namespace, or use:
./deploy.sh --set namespace=cte-system
```

## Helm Commands (Direct)

For advanced users, Helm commands can be executed directly:

### View Generated Templates
```bash
cd deploy/deploy/kubernetes
helm template 2.0.0 \
  --set csi.enabled=true \
  --set cos.enabled=true
```

### Dry Run
```bash
helm upgrade --install cte-csi-deployment 2.0.0 \
  --namespace kube-system \
  --dry-run \
  --set csi.enabled=true \
  --set cos.enabled=true
```

### Check Current Release Values
```bash
helm get values cte-csi-deployment -n kube-system
```

### List Releases
```bash
helm list -n kube-system
```

## Best Practices

1. **Always backup your configuration** before major upgrades
2. **Test in a dev environment** before deploying to production
3. **Use explicit tags** rather than `latest`
4. **Verify pod readiness** before creating workloads
5. **Monitor logs** after deployment for any issues
6. **Keep credentials secure** when using private registries

## Getting Help

```bash
# Display help
./deploy.sh --help

# Check version
./deploy.sh --tag latest

# View Helm chart details
helm show values deploy/kubernetes/2.0.0
```

## Related Documentation

- **CTE K8s User Guide**: https://thalesdocs.com/ctp/cte-con/cte-k8s/latest/
- **Helm Documentation**: https://helm.sh/docs/
- **Kubernetes CSI**: https://kubernetes-csi.github.io/
- **Custom Resource Definitions**: https://kubernetes.io/docs/tasks/extend-kubernetes/custom-resources/custom-resource-definitions/
