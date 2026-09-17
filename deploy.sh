#!/bin/bash

if [ -t 1 ]; then
        PS4=$'\e[35m+${BASH_SOURCE}\e[0m:\e[33m${LINENO}\e[0m:\e[36m${FUNCNAME[0]}()\e[0m: '
else
        PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}(): '
fi

USER=""
PASSWD=""
SERVER=""
IMAGE=""
CATALOG_IMG=""

CSI_DEPLOYMENT_NAME="cte-csi-deployment"
CRISOCK=""
DEPLOY_FILE_DIR=deploy

IMAGE_PULL_SECRET="cte-csi-secret"
CSI_DRIVER_CONFIGMAP="cte-k8s-config"

# Default registry (can be overridden via --server)
DEFAULT_SERVER="docker.io"

# Deployment mode: csi, cos, or both (default: both).
# Forwarded to operator-deploy/deploy.sh (2.0.0+) to control which resources to deploy/remove.
# Older operator-deploy scripts that don't support --deploy-mode won't receive it (detected via grep).
DEPLOY_MODE="both"

# Default namespaces for operator deployment
OPERATOR=YES
OPR_NS_ARG=0
CTE_K8S_NS_ARG=0
OPERATOR_NS="kube-system"
CTE_K8S_NS="kube-system"
ECHO="echo -e"
GREP="grep"


chk_pkgs()
{
    if ! [ -x "$(command -v kubectl)" ]; then
        echo "Error: 'kubectl' is not installed or not in PATH." >&2
        exit 1
    fi

    IS_OCP=`kubectl api-resources | awk -F' ' '{ print $2 }' | grep route.openshift.io | wc -l`

    if [ ${IS_OCP} -ge 1 ]; then
        if ! [ -x "$(command -v oc)" ]; then
            echo "Error: Openshift CLI command 'oc' is not installed or not in PATH." >&2
            exit 1
        fi
        OC_KUBECTL_CMD=`which oc`
    else
        OC_KUBECTL_CMD=`which kubectl`
    fi
}

kube_create_secret()
{
    DEPLOY_NAMESPACE=$1
    # Skip if User or Password not set
    if [ -z "${USER}" ] || [ -z "${PASSWD}" ] || [ -z "${SERVER}" ]; then
        return
    fi

    kubectl get secrets ${IMAGE_PULL_SECRET} --namespace=${DEPLOY_NAMESPACE} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
        kubectl delete secrets ${IMAGE_PULL_SECRET} --namespace=${DEPLOY_NAMESPACE}
        if [ $? -ne 0 ]; then
            exit 1
        fi
    fi

    # TODO: Need to make sure to test with container runtimes other than Docker.
    RUN_CMD="kubectl create secret docker-registry ${IMAGE_PULL_SECRET}
        --docker-server=${SERVER} --docker-username=${USER}
        --docker-password=${PASSWD} --namespace=${DEPLOY_NAMESPACE}"
    echo ${RUN_CMD}
    ${RUN_CMD}
    if [ $? -ne 0 ]; then
        exit 1
    fi
}

validate_remove_mode()
{
    local ACTUAL_DEPLOY_MODE="$1"

    case "${DEPLOY_MODE}" in
        both)
            # 'both' is valid and bypasses the strict cluster match check. Do nothing.
            ;;
        cos|csi)
            # These are valid modes, but they MUST match the cluster state if one is already deployed.
            if [[ -n "${ACTUAL_DEPLOY_MODE}" && "${ACTUAL_DEPLOY_MODE}" != "${DEPLOY_MODE}" ]]; then
                echo "Error: Deployment mode conflict. The active installation is in '${ACTUAL_DEPLOY_MODE}' deploy mode, but the requested is '--deploy-mode=${DEPLOY_MODE}'." >&2
                exit 1
            fi
            ;;
        *)
            # Catch-all for invalid input
            echo "Error: Invalid deploy mode '${DEPLOY_MODE}'. Allowed values are 'cos', 'csi', or 'both'." >&2
            exit 1
            ;;
    esac
}

remove()
{
     # Bail out if any application is using CTE K8s Volume(s)
    pod_count=$(${OC_KUBECTL_CMD} get pods --all-namespaces | ${GREP} "cte-staging-pod" | wc -l)
    if [ $pod_count -ge 1 ]; then
        ${ECHO} "                    !!! WARNING !!!"
        ${ECHO} "At least one application appears to be using CipherTrust Transparent Encryption for Kubernetes Volume(s). Can not un-install CipherTrust Transparent Encryption for Kubernetes"
        ${ECHO} "                    !!! WARNING !!!"

        exit 1
    fi 

    cmrc_count=$(${OC_KUBECTL_CMD} get cmregistrationclasses --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "${cmrc_count}" -ge 1 ]; then
       ${ECHO} "                    !!! WARNING !!!"
       ${ECHO} "${cmrc_count} CMRegistrationClass instance(s) still exist in the cluster."
       ${ECHO} "Delete all CMRegistrationClass instances before removing the operator."
       ${ECHO} "                    !!! WARNING !!!"
       exit 1
    fi

    while [ "x${CTE_K8S_NS}" = "x" ]; do
        ${ECHO} -n "Namepace in which CipherTrust Transparent Encryption for Kubernetes is deployed: "
        read CTE_K8S_NS
    done
    
    if [[ ${OPERATOR} == "YES" ]]; then
        # Case with cte-csi was installed using helm, but attempt to remove using operator
        if [ -x "$(command -v helm)" ]; then
            helm list -q --all-namespaces 2>/dev/null | grep -q cte-csi-deployment
            if [ $? -eq 0 ]; then
                echo "Error: CTE for Kubernetes was installed using helm. Try --remove with the --helm parameter [and remove --operator/-o if added]"
                exit 1
            fi
        fi

        while [ "x${OPERATOR_NS}" = "x" ]; do
            ${ECHO} -n "Namepace in which CipherTrust Transparent Encryption for Kubernetes Operator is deployed: "
            read OPERATOR_NS
        done

        # Validate --deploy-mode against the live CteK8sOperator CR spec.deployMode (operator mode only).
        ACTUAL_DEPLOY_MODE=$(${OC_KUBECTL_CMD} get ctek8soperators.cte-k8s-operator.csi.cte.cpl.thalesgroup.com ctek8soperator -n ${OPERATOR_NS} -o jsonpath='{.spec.deployMode}' 2>/dev/null)
        # spec.deployMode is absent in operator crd then default to "csi"
        if [ -z "${ACTUAL_DEPLOY_MODE}" ]; then
            ACTUAL_DEPLOY_MODE="csi"
        fi
        validate_remove_mode "${ACTUAL_DEPLOY_MODE}"

        OPERATOR_DEPLOY_FILE_DIR=${DEPLOY_FILE_DIR}/kubernetes/${CHART_VERSION}/operator-deploy
        OPR_REMOVE_CMD="${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh --tag=${CHART_VERSION} --operator-ns=${OPERATOR_NS} --cte-ns=${CTE_K8S_NS} --remove"
        # Only forward --deploy-mode if explicitly provided by the user.
        if [ -n "${DEPLOY_MODE}" ] && grep -q "deploy-mode" "${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh" 2>/dev/null; then
            OPR_REMOVE_CMD="${OPR_REMOVE_CMD} --deploy-mode=${DEPLOY_MODE}"
        fi
        ${OPR_REMOVE_CMD}
        kubectl get secrets ${IMAGE_PULL_SECRET} --namespace=${CTE_K8S_NS} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete secrets ${IMAGE_PULL_SECRET} --namespace=${CTE_K8S_NS} 2> /dev/null
        fi
        ${OC_KUBECTL_CMD} delete catsrc ctek8soperator-catalog -n ${OPERATOR_NS} --ignore-not-found=true
	exit 0
    fi

    # Case where cte-csi was possibly installed using operator, but attempt to remove using helm (without the --operator arg)
    if [ -x "$(command -v helm)" ]; then
        helm list -q --all-namespaces 2>/dev/null | grep -q cte-csi-deployment
        if [ $? -eq 1 ]; then
            echo "Error: CTE for Kubernetes deployment not found. Was it installed using --operator?"
            exit 1
        fi
        
        # Fetch ACTUAL_DEPLOY_MODE via helm get values and validate before deleting
        HELM_VALS=$(helm get values cte-csi-deployment -n "${CTE_K8S_NS}" -a 2>/dev/null)
        has_cos=$(echo "$HELM_VALS" | grep -A 10 "^cos:" | grep -Eq "enabled:[[:space:]]*true" && echo "true" || echo "false")
        has_csi=$(echo "$HELM_VALS" | grep -A 10 "^csi:" | grep -Eq "enabled:[[:space:]]*true" && echo "true" || echo "false")

        if [[ "${has_csi}" == "true" && "${has_cos}" != "true" ]]; then
            ACTUAL_DEPLOY_MODE="csi"
        elif [[ "${has_cos}" == "true" && "${has_csi}" != "true" ]]; then
            ACTUAL_DEPLOY_MODE="cos"
        else
            ACTUAL_DEPLOY_MODE="both"
        fi

        validate_remove_mode "${ACTUAL_DEPLOY_MODE}"
    fi

    # Use CTE_K8S_NS for removal (can be overridden via --cte-ns)
    if [[ "${REMOVE}" == "YES" ]]; then
        kubectl get secrets ${IMAGE_PULL_SECRET} --namespace=${CTE_K8S_NS} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete secrets ${IMAGE_PULL_SECRET} --namespace=${CTE_K8S_NS} 2> /dev/null
        fi
        kubectl get cm ${CSI_DRIVER_CONFIGMAP} --namespace=${CTE_K8S_NS} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete cm ${CSI_DRIVER_CONFIGMAP} --namespace=${CTE_K8S_NS} 2> /dev/null
        fi
    fi

    helm delete --namespace=${CTE_K8S_NS} ${CSI_DEPLOYMENT_NAME} 2> /dev/null
    exit 0
}

kube_autodetect_crisocket()
{
	if [ -n "${CRISOCK}" ]; then
		echo "Automatic detection of CRI socket is disabled, using user provided path"
		return
	fi
        echo "Automatic detection of CRI socket is enabled"
	# detect CRI socket path based on kubeadm annotations.
	KUBECTL_OUT=`kubectl get nodes -o jsonpath='{range .items[0]}{.metadata.annotations.kubeadm\.alpha\.kubernetes\.io/cri-socket}'`
	if [ $? -ne 0 ]; then
		exit 1
	fi
	CRISOCK=${KUBECTL_OUT#"unix://"}
	if [ -n "${CRISOCK}" ]; then
		echo "Found exact CRI socket path using kubeadm annotations."
		return
	fi
	# detect container runtime
	KUBECTL_OUT=`kubectl get node -o=jsonpath="{.items[0].status.nodeInfo.containerRuntimeVersion}"`
	if [ $? -ne 0 ]; then
		exit 1
	fi
	# retrieve container runtime name from kubectl output, ex: cri-o://1.25.1
	CRT=${KUBECTL_OUT%://*}
	if [ -n "$CRT" ]; then
		case $CRT in
			containerd)
				CRISOCK="/run/containerd/containerd.sock"
				;;
			cri-o)
				CRISOCK="/run/crio/crio.sock"
				;;
			docker)
				CRISOCK="/run/cri-dockerd.sock"
				;;
			*)
				echo "Unsupported container runtime $CRT"
				CRISOCK=
				;;
		esac
		if [ -n "$CRISOCK" ]; then
			echo "Using default CRI socket path $CRISOCK for container runtime $CRT"
			return
		fi
	fi
	echo "Unable to detect CRI socket path for your configuration. Provide path with --cri-sock option."
	exit 1
}

install_operator()
{
    if [ -x "$(command -v helm)" ]; then
        helm list -q --all-namespaces 2>/dev/null | grep -q cte-csi-deployment
        if [ $? -eq 0 ]; then
            echo "Error: CTE for Kubernetes was installed using helm. Please refer to the"
            echo "CTE-K8s user guide, for steps to migrate from Helm to Operator based deployment"
            exit 1
        fi
    fi

    OPERATOR_DEPLOY_FILE_DIR=${DEPLOY_FILE_DIR}/kubernetes/${CHART_VERSION}/operator-deploy

    kube_create_secret ${CTE_K8S_NS}
    if [ "${OPERATOR_NS}" != "${CTE_K8S_NS}" ]; then
        kube_create_secret ${OPERATOR_NS}
    fi

    # If custom image is provided, modify the CRD YAML file before deploying
    if [ -n "${IMAGE}" ]; then
        echo "Using custom image for operator deployment: ${IMAGE}"
        # Escape forward slashes for sed
        ESCAPED_IMAGE=$(echo "${IMAGE}" | sed 's#/#\\/#g')
        sed -i "s#^  image: .*#  image: \"${ESCAPED_IMAGE}\"#g" "${OPERATOR_DEPLOY_FILE_DIR}/ctek8soperator-crd.yaml"
    fi

    # If a specific tag is provided via -t/--tag, also update the version: field in the CRD YAML.
    # The CRD hardcodes a default version (e.g. "2.X.X-latest") which is used as the image tag
    # when pulling the CSI driver image. Without this patch, -t 2.X.X.XX would still pull the
    # hardcoded default tag instead of the requested one.
    if [ -n "${CSI_TAG}" ]; then
        echo "Updating CRD version to: ${CSI_TAG}"
        sed -i "s#^  version: .*#  version: \"${CSI_TAG}\"#g" "${OPERATOR_DEPLOY_FILE_DIR}/ctek8soperator-crd.yaml"
    fi

    # Build the operator-deploy command.
    # --deploy-mode and --catalog-img are optional flags supported only in 2.0.0+.
    # Older operator-deploy scripts do not accept these flags, so we only pass them when the target script supports them (detected via grep).
    OPR_DEPLOY_CMD="${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh --tag=${CHART_VERSION} --operator-ns=${OPERATOR_NS} --cte-ns=${CTE_K8S_NS} --sock=${CRISOCK}"
    if [ -n "${DEPLOY_MODE}" ] && grep -q "deploy-mode" "${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh" 2>/dev/null; then
        OPR_DEPLOY_CMD="${OPR_DEPLOY_CMD} --deploy-mode=${DEPLOY_MODE}"
    fi
    if [ -n "${CATALOG_IMG}" ] && grep -q "catalog-img" "${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh" 2>/dev/null; then
        OPR_DEPLOY_CMD="${OPR_DEPLOY_CMD} --catalog-img=${CATALOG_IMG}"
    fi
    ${OPR_DEPLOY_CMD}

    exit 0
}

get_chart_version() {
    #Tag can be of form "latest", "X.Y.Z-latest", "latest-X.Y.Z" or "X.Y.Z.NNNN"
    echo $1 | awk 'BEGIN { OFS="."; FS="[.-]" } {
        if (NF == 1) {
                if ( $1 == "latest" )
                        print "latest"
        } else if (NF == 4) {
                if ( $1 == "latest" )
                        print $2,$3,$4
                else
                        print $1,$2,$3
        } else {
                print "InvalidTag"
        }
    }'
}

# need to remove cte csi driver before upgrading from older charts without fsGroupPolicy set to "File"
# otherwise upgrading will fail as fsGroupPolicy field is marked as immutable
kube_fsgroup_upgrade_fix()
{
    FSGROUPPOLICY=`kubectl get csidriver csi.cte.cpl.thalesgroup.com -o=jsonpath="{.spec.fsGroupPolicy}" 2>/dev/null`
    if [ $? -ne 0 ] || [ -z "$FSGROUPPOLICY" ]; then
        return
    fi
    if [ "$FSGROUPPOLICY" != "File" ]; then
        kubectl delete csidriver csi.cte.cpl.thalesgroup.com
    fi
}

# Validate image format
# Expected format: registry.com/repo/image-name or repo/image-name
validate_image()
{
    local image=$1

    # Check if image is empty
    if [ -z "${image}" ]; then
        return 0  # Empty is valid (will use default)
    fi

    # Check for invalid characters (spaces, special chars except /, -, ., :)
    if echo "${image}" | grep -qE '[[:space:]|<>(){}]'; then
        echo "Error: Invalid image format '${image}'"
        echo "Image should not contain spaces or special characters"
        return 1
    fi

    # Check if image contains at least one forward slash (registry/repo or repo/image)
    if ! echo "${image}" | grep -q '/'; then
        echo "Error: Invalid image format '${image}'"
        echo "Image should be in format: registry.com/repo/image-name or repo/image-name"
        return 1
    fi

    return 0
}

start()
{
    chk_pkgs

    if [ ! -v "CSI_TAG" ]; then
        CHART_VERSION="latest"
    else
        CHART_VERSION=`get_chart_version $CSI_TAG`
	if [[ "${CHART_VERSION}" == "InvalidTag" ]]; then
            echo "Invalid tag version - ${CSI_TAG}"
            exit 1
        fi
    fi

    # some variables have to be set before we call remove for operator
    if [[ ${REMOVE} == "YES" ]]; then
        remove
    fi

    # Validate the existing deployment and perform a namespace sanity check.
    # CSI and COS must be same namespace. Different namespaces for COS and CSI components is not supported.
    existing_csi="false"
    existing_cos="false"

    # Check for existing CSI components (Controller and Nodeserver) across all namespaces
    csi_ctrl_ns=$(${OC_KUBECTL_CMD} get deployment.apps -A -o jsonpath='{.items[?(@.metadata.name=="cte-csi-controller")].metadata.namespace}' 2>/dev/null)
    csi_node_ns=$(${OC_KUBECTL_CMD} get daemonset.apps -A -o jsonpath='{.items[?(@.metadata.name=="cte-csi-node")].metadata.namespace}' 2>/dev/null)

    # Verify if both CSI components are present and match namespaces
    if [ -n "$csi_ctrl_ns" ] && [ -n "$csi_node_ns" ]; then
        # Check if installed CSI Controller and Nodeserver namespace mismatch (unlikely)
        if [ "$csi_ctrl_ns" != "$csi_node_ns" ]; then
            echo "Error: Detection mismatch! The CTE-CSI Controller is in '${csi_ctrl_ns}' but the CTE-CSI Nodeserver is in '${csi_node_ns}'."
            echo "Both cte-csi-controller and cte-csi-node modules must be in the same namespace."
            echo "CTE-K8s should be completely installed in the same namespace."
            exit 1
        fi
        # Check if CSI is found in a namespace other than current namsepace, block deployment
        # Now both found in same namespace, check against either controller or nodeserver namespace,
        if [ "$csi_ctrl_ns" != "${CTE_K8S_NS}" ]; then
            echo "Error: Found existing CSI deployment in namespace '${csi_ctrl_ns}', but the current namespace is '${CTE_K8S_NS}'."
            echo "CSI and COS cannot be installed in different namespaces. If upgrading then must be in same namespace."
            exit 1
        fi
        existing_csi="true"
    elif [ -n "$csi_ctrl_ns" ] && [ -z "$csi_node_ns" ]; then
        # Handle partial/broken CSI installations, Controller found, But Nodeserver is missing
        echo "Error: Partial CSI deployment found. CTE-CSI Controller found in namespace '${csi_ctrl_ns}', but CTE-CSI Nodeserver is missing."
        exit 1
    elif [ -n "$csi_node_ns" ] && [ -z "$csi_ctrl_ns" ]; then
        # Handle partial/broken CSI installations, Nodeserver found, But Controller is missing
        echo "Error: Partial CSI deployment found. CTE-CSI Nodeserver found in namespace '${csi_node_ns}', but CTE-CSI Controller is missing."
        exit 1
    fi

    # Check for existing COS deployment across all namespaces
    cos_namespace=$(${OC_KUBECTL_CMD} get deployment.apps -A -o jsonpath='{.items[?(@.metadata.name=="cte-cos-controller-deployment")].metadata.namespace}' 2>/dev/null)

    if [ -n "$cos_namespace" ]; then
        # If found in a different namespace, block deployment
        if [ "$cos_namespace" != "${CTE_K8S_NS}" ]; then
            echo "Error: Found existing COS deployment in namespace '${cos_namespace}', but the current namespace is '${CTE_K8S_NS}'."
            echo "CSI and COS cannot be installed in different namespaces. If upgrading then must be in same namespace."
            exit 1
        fi
        existing_cos="true"
    fi

    # Set deployment mode flags based on DEPLOY_MODE
    case ${DEPLOY_MODE} in
        csi)
            # If --deploy-mode=csi, then any exsting COS deployment should not be removed. Fail if COS found.
            if [[ "$existing_csi" == "false" && "$existing_cos" == "false" ]]; then
                echo "No existing deployment found. Installing CSI..."
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "false" ]]; then
                echo "Found existing CSI. Upgrading..."
            elif [[ "$existing_csi" == "false" && "$existing_cos" == "true" ]]; then
                echo "Error: deployment mode '${DEPLOY_MODE}' can not be use. Found existing COS deployment. To add CSI alongside existing COS, use --deploy-mode=both instead of --deploy-mode=csi"
                exit 1
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "true" ]]; then
                echo "Error: deployment mode '${DEPLOY_MODE}' can not be use. Found existing both (CSI & COS) deployment. To upgrade use --deploy-mode=both instead of --deploy-mode=csi"
                exit 1
            fi

            EXTRA_OPTIONS="${EXTRA_OPTIONS} --set csi.enabled=true --set cos.enabled=false"
            ;;
        cos)
            # If --deploy-mode=cos, then any exsting CSI deployment should not be removed
            if [[ "$existing_csi" == "false" && "$existing_cos" == "false" ]]; then
                echo "No existing deployment found. Installing COS..."
            elif [[ "$existing_csi" == "false" && "$existing_cos" == "true" ]]; then
                echo "Found existing COS. Upgrading..."
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "false" ]]; then
                echo "Error: deployment mode '${DEPLOY_MODE}' can not be use. Found existing CSI deployment. To add COS alongside existing CSI, use --deploy-mode=both instead of --deploy-mode=cos"
                exit 1
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "true" ]]; then
                echo "Error: deployment mode '${DEPLOY_MODE}' can not be use. Found existing both (CSI & COS) deployment. To upgrade use --deploy-mode=both instead of --deploy-mode=cos"
                exit 1
            fi

            EXTRA_OPTIONS="${EXTRA_OPTIONS} --set csi.enabled=false --set cos.enabled=true"
            ;;
        both)
            if [[ "$existing_csi" == "false" && "$existing_cos" == "false" ]]; then
                echo "No existing deployment found. Installing CSI & COS..."
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "false" ]]; then
                echo "Found existing CSI. Installing COS..."
            elif [[ "$existing_csi" == "false" && "$existing_cos" == "true" ]]; then
                echo "Found existing COS. Installing CSI..."
            elif [[ "$existing_csi" == "true" && "$existing_cos" == "true" ]]; then
                echo "Found existing CSI & COS. Upgrading..."
            fi

            EXTRA_OPTIONS="${EXTRA_OPTIONS} --set csi.enabled=true --set cos.enabled=true"
            ;;
        *)
            echo "Error: Invalid deployment mode '${DEPLOY_MODE}'. Valid modes are: csi, cos, both"
            exit 1
            ;;
    esac


    # Validate custom image if provided
    if [ -n "${IMAGE}" ]; then
        validate_image "${IMAGE}"
        if [ $? -ne 0 ]; then
            exit 1
        fi
        echo "Using custom image: ${IMAGE}"
    fi

    kube_autodetect_crisocket
    echo "Using CRISocket path:" ${CRISOCK}
    EXTRA_OPTIONS="${EXTRA_OPTIONS} --set csi.CRISocket=${CRISOCK}"

    kube_fsgroup_upgrade_fix

    # Set default server if not provided
    if [ -z "${SERVER}" ]; then
        SERVER=${DEFAULT_SERVER}
    fi

    if [[ ${OPERATOR} == "YES" ]]; then
        install_operator
    fi

    # Add custom image to Helm options if provided
    if [ -n "${IMAGE}" ]; then
        EXTRA_OPTIONS="${EXTRA_OPTIONS} --set image.cteCsiImage=${IMAGE}"
    fi

    # Add custom tag to Helm options if provided
    if [ -n "${CSI_TAG}" ]; then
        EXTRA_OPTIONS="${EXTRA_OPTIONS} --set image.cteCsiTag=${CSI_TAG}"
    fi

    if ! [ -x "$(command -v helm)" ]; then
        echo "Error: 'helm' is not installed or not in PATH." >&2
        exit 1
    fi

    # Use CTE_K8S_NS for Helm deployment (can be overridden via --cte-ns flag)
    # If not overridden, it uses the default value "kube-system"
    kube_create_secret ${CTE_K8S_NS}

    echo "Deploying CTE services (mode: ${DEPLOY_MODE}) to namespace ${CTE_K8S_NS} using helm chart..."
    cd "${DEPLOY_FILE_DIR}/kubernetes"

    # Pass namespace to Helm chart templates
    EXTRA_OPTIONS="${EXTRA_OPTIONS} --set namespace=${CTE_K8S_NS}"

    # Set imagePullSecrets based on whether credentials were provided
    # If USER/PASSWD/SERVER are not provided, disable imagePullSecrets in templates
    if [ -z "${USER}" ] || [ -z "${PASSWD}" ] || [ -z "${SERVER}" ]; then
        EXTRA_OPTIONS="${EXTRA_OPTIONS} --set imagePullSecrets=null"
        echo "No registry credentials provided - deploying without imagePullSecrets"
    else
        echo "Registry credentials provided - using imagePullSecrets: cte-csi-secret"
    fi

    # "upgrade --install" will install if no prioir install exists, else upgrade
    if [ ! -v HELM_CMD ]; then
        # the HELM_CMD variable is not defined
        HELM_CMD="helm upgrade --install --namespace=${CTE_K8S_NS} ${CSI_DEPLOYMENT_NAME}"
        HELM_CMD="${HELM_CMD} ./${CHART_VERSION} ${EXTRA_OPTIONS}"
    else
        # We are being called from a wrapper script, which defines HELM_CMD
	HELM_CMD="${HELM_CMD} --namespace=${CTE_K8S_NS}"
        HELM_CMD="${HELM_CMD} ${CSI_DEPLOYMENT_NAME} ./${CHART_VERSION} ${EXTRA_OPTIONS}"
    fi
    echo ${HELM_CMD}
    ${HELM_CMD}
}

usage()
{
    echo  "Options :"
    echo  "-i | --image=    Custom image repository/name"
    echo  "                             Format: registry.com/repo/image-name"
    echo  "                             Example: myregistry.io/myteam/cte-k8s"
    echo  "--catalog-img=   Operator catalog image (overrides default DockerHub image)"
    echo  "                             Works with --operator mode"
    echo  "                             Use for internal registry"
    echo  "-t | --tag=      Tag of image on the server"
    echo  "                             Default: 2.0.0-latest (from values.yaml)"
    echo  "--deploy-mode=   Deployment mode: csi, cos, or both"
    echo  "                             Default: both"
    echo  "-r | --remove    Undeploy the services and exit"
    echo  "-o | --operator  Deploy CTE-K8s Operator and CSI driver"
    echo  "                             Note: --image works with operator deployment"
    echo  "--operator-ns=   The namespace in which to deploy the Operator"
    echo  "                             (Only for --operator mode)"
    echo  "--cte-ns=        The namespace in which to deploy CTE K8s services"
    echo  "                             Works with both --helm and --operator modes"
    echo  "                             Default: kube-system"
    echo  "--cri-sock=      Container Runtime Interface socket path"
    echo  "--helm           Deploy using Helm (default, unless --operator specified)"
}

# main

L_OPTS="server:,user:,passwd:,tag:,image:,catalog-img:,remove,help,operator-ns:,cte-ns:,operator,cri-sock:,helm,deploy-mode:"
S_OPTS="s:u:p:t:i:rho"
options=$(getopt -a -l ${L_OPTS} -o ${S_OPTS} -- "$@")
if [ $? -ne 0 ]; then
        exit 1
fi
eval set -- "$options"

while true ; do
    case $1 in
        -h|--help)
            usage
            exit 0
            ;;
        -s|--server)
            SERVER=${2}
            shift 2
            ;;
        -u|--user)
            USER=${2}
            shift 2
            ;;
        -p|--passwd)
            PASSWD=${2}
            shift 2
            ;;
        -t|--tag)
             CSI_TAG=${2}
             shift 2
             ;;
        -i|--image)
             IMAGE=${2}
             shift 2
             ;;
        --catalog-img)
             CATALOG_IMG=${2}
             shift 2
             ;;
        --deploy-mode)
             DEPLOY_MODE=${2}
             shift 2
             ;;
         -r|--remove)
             REMOVE="YES"
             shift
             ;;
        -o|--operator)
            OPERATOR="YES"
            shift
            ;;
       --operator-ns)
            OPR_NS_ARG=1
            OPERATOR_NS=${2}
            shift 2
            ;;
       --cte-ns)
            CTE_K8S_NS_ARG=1
            CTE_K8S_NS=${2}
            shift 2
            ;;
       --cri-sock)
            CRISOCK=${2}
            shift 2
            ;;
       --helm)
            OPERATOR="NO"
            shift
            ;;
        --)
            shift
            break
            ;;
        *)
            echo -n "unknown option: ${1}"
            exit 1
            ;;

    esac
done

if [ ${OPR_NS_ARG} -eq 1 ]; then
    if [ "${OPERATOR}" = "NO" ]; then
        echo "the --operator-ns parameter is supported only with --operator parameter"
        exit 1
    fi
fi

# Note: --cte-ns now works with both --operator and --helm modes

if [[ "${REMOVE}" == "YES" ]]; then
    echo "Removing CTE services (mode: ${DEPLOY_MODE})."
else
    echo "Starting CTE services (mode: ${DEPLOY_MODE})."
fi

start
