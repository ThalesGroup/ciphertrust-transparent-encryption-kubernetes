#!/bin/bash

USER=""
PASSWD=""
SERVER=""

CSI_DEPLOYMENT_NAME="cte-csi-deployment"
CRISOCK=""
DEPLOY_NAMESPACE="kube-system"
DEPLOY_FILE_DIR=deploy

IMAGE_PULL_SECRET="cte-csi-secret"
CSI_DRIVER_CONFIGMAP="cte-k8s-config"

# Default namespaces for operator deployment
OPERATOR=YES
OPR_NS_ARG=0
CSI_NS_ARG=0
OPERATOR_NS="kube-system"
CSI_NS="kube-system"

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

check_exec() {
    if ! [ -x "$(command -v ${1})" ]; then
        echo "Error: '${1}' is not installed or not in PATH." >&2
        exit 1
    fi
}

remove()
{
    if [[ ${OPERATOR} == "YES" ]]; then
        # Case with cte-csi was installed using helm, but attempt to remove using operator
        if [ -x "$(command -v helm)" ]; then
            helm list -q --all-namespaces 2>/dev/null | grep -q cte-csi-deployment
            if [ $? -eq 0 ]; then
                echo "Error: CTE for Kubernetes was installed using helm. Try --remove with the --helm parameter [and remove --operator/-o if added]"
                exit 1
            fi
        fi

        OPERATOR_DEPLOY_FILE_DIR=${DEPLOY_FILE_DIR}/kubernetes/${CHART_VERSION}/operator-deploy
        ${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh --tag=${CHART_VERSION} --operator-ns=${OPERATOR_NS} --cte-ns=${CSI_NS} --remove
        kubectl get secrets ${IMAGE_PULL_SECRET} --namespace=${CSI_NS} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete secrets ${IMAGE_PULL_SECRET} --namespace=${CSI_NS} 2> /dev/null
        fi
        exit 0
    fi

    # Case where cte-csi was possibly installed using operator, but attempt to remove using helm (without the --operator arg)
    if [ -x "$(command -v helm)" ]; then
        helm list -q --all-namespaces 2>/dev/null | grep -q cte-csi-deployment
        if [ $? -eq 1 ]; then
            echo "Error: CTE for Kubernetes deployment not found. Was it installed using --operator?"
            exit 1
        fi
    fi

    DEPLOY_NAMESPACE=$(grep namespace deploy/kubernetes/${CHART_VERSION}/values.yaml | sed -e s/[" "\"]//g | cut -d":" -f2)
    if [[ "${REMOVE}" == "YES" ]]; then
        kubectl get secrets ${IMAGE_PULL_SECRET} --namespace=${DEPLOY_NAMESPACE} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete secrets ${IMAGE_PULL_SECRET} --namespace=${DEPLOY_NAMESPACE} 2> /dev/null
        fi
        kubectl get cm ${CSI_DRIVER_CONFIGMAP} --namespace=${DEPLOY_NAMESPACE} > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            kubectl delete cm ${CSI_DRIVER_CONFIGMAP} --namespace=${DEPLOY_NAMESPACE} 2> /dev/null
        fi
    fi

    helm delete --namespace=${DEPLOY_NAMESPACE} ${CSI_DEPLOYMENT_NAME} 2> /dev/null
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
    kube_create_secret ${CSI_NS}
    ${OPERATOR_DEPLOY_FILE_DIR}/deploy.sh --tag=${CHART_VERSION} --operator-ns=${OPERATOR_NS} --cte-ns=${CSI_NS} --sock=${CRISOCK}

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

start()
{
    check_exec kubectl

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

    kube_autodetect_crisocket
    echo "Using CRISocket path:" ${CRISOCK}
    EXTRA_OPTIONS="${EXTRA_OPTIONS} --set CRISocket=${CRISOCK}"

    kube_fsgroup_upgrade_fix

    if [[ ${OPERATOR} == "YES" ]]; then
        install_operator
    fi

    check_exec helm

    # Get the namespace for deploying CTE-K8s from values.yaml. It could be of form
    # namespace: "kube-system" or namespace: kube-system
    # convert it to form namespace:kube-system, then split on colon
    DEPLOY_NAMESPACE=$(grep namespace deploy/kubernetes/${CHART_VERSION}/values.yaml | sed -e s/[" "\"]//g | cut -d":" -f2)
    kube_create_secret ${DEPLOY_NAMESPACE}

    echo "Deploying $CSI_DEPLOYMENT_NAME using helm chart..."
    cd "${DEPLOY_FILE_DIR}/kubernetes"

    # "upgrade --install" will install if no prioir install exists, else upgrade
    if [ ! -v HELM_CMD ]; then
        # the HELM_CMD variable is not defined
        HELM_CMD="helm upgrade --install --namespace=${DEPLOY_NAMESPACE} ${CSI_DEPLOYMENT_NAME}"
        HELM_CMD="${HELM_CMD} ./${CHART_VERSION} ${EXTRA_OPTIONS}"
    else
        # We are being called from a wrapper script, which defines HELM_CMD
	HELM_CMD="${HELM_CMD} --namespace=${DEPLOY_NAMESPACE}"
        HELM_CMD="${HELM_CMD} ${CSI_DEPLOYMENT_NAME} ./${CHART_VERSION} ${EXTRA_OPTIONS}"
    fi
    echo ${HELM_CMD}
    ${HELM_CMD}
}

usage()
{
    echo  "Options :"
    echo  "-t | --tag=      Tag of image on the server"
    echo  "                             Default: latest"
    echo  "-r | --remove    Undeploy the CSI driver and exit"
    echo  "-o | --operator  Deploy CTE-K8s Operator and CSI driver"
    echo  "--operator-ns=   The namespace in which to deploy the Operator"
    echo  "--cte-ns=        The namespace in which to deploy the CSI driver"
    echo  "--cri-sock=      Container Runtime Interface socket path"
}

# main

L_OPTS="server:,user:,passwd:,tag:,remove,help,operator-ns:,cte-ns:,operator,cri-sock:,helm"
S_OPTS="s:u:p:t:rho"
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
            CSI_NS_ARG=1
            CSI_NS=${2}
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

if [ ${OPR_NS_ARG} -eq 1 ] || [ ${CSI_NS_ARG} -eq 1 ]; then
    if [ "${OPERATOR}" = "NO" ]; then
        echo "the --operator-ns and --cte-ns parameters are supported only with --operator parameter"
        exit 1
    fi
fi

if [[ "${REMOVE}" == "YES" ]]; then
    echo "Removing the cte-csi containers."
else
    echo "Starting the cte-csi containers."
fi

start
