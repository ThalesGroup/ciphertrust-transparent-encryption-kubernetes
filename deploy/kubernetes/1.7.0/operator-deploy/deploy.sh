#!/bin/bash

SILENT_INSTALL=0
OPR_NS_SUPPLIED=0
CTEK8S_NS_SUPPLIED=0
CLEANUP=0
DEPLOY_SCRIPT_PATH=""

ECHO="echo -e"
AWK="awk"
GREP="grep"

#The top level deploy script has already checked for kubectl command.
IS_OCP=$(kubectl api-resources | awk -F' ' '{ print $2 }' | grep route.openshift.io | wc -l)
chk_pkgs()
{
    if [ ${IS_OCP} -ge 1 ]; then
        if ! [ -x "$(command -v oc)" ]; then
            echo "Error: Openshift CLI command 'oc' is not installed or not in PATH." >&2
            exit 1
        fi
	OC_KUBECTL_CMD=$(which oc)
    else
        OC_KUBECTL_CMD=$(which kubectl)
    fi
}

print_msg()
{
    if [ ${SILENT_INSTALL} -ne 1 ]; then
        echo $1
    fi
}

parse_cmdline()
{
    for i in "$@"; do
        case $i in
            -s|--silent)
                SILENT_INSTALL=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --operator-ns=*)
                OPR_NS_SUPPLIED=1
                OPR_NS="${i#*=}"
                ;;
            --cte-ns=*)
                CTEK8S_NS_SUPPLIED=1
                CTEK8S_NS="${i#*=}"
                ;;
            --remove)
                CLEANUP=1
                ;;
            --sock=*)
                CRISOCK="${i#*=}"
                ;;
            --tag=*)
                CSI_TAG="${i#*=}"
                ;;
            *)
                ${ECHO} "Unknown Options"
                exit 1
            esac
    done

    DEPLOY_SCRIPT_PATH=deploy/kubernetes/${CSI_TAG}/operator-deploy

    if [ ${SILENT_INSTALL} -eq 1 ]; then
        if [ -z ${OPR_NS} ]; then
            OPR_NS="kube-system"
        fi
        if [ -z ${CTEK8S_NS} ]; then
            CTEK8S_NS="kube-system"
        fi
    fi

    if [ ${OPR_NS_SUPPLIED} -eq 1 ] && [ ${CTEK8S_NS_SUPPLIED} -eq 1 ]
    then
        SILENT_INSTALL=1
    fi

    if [ ${CLEANUP} -eq 1 ]; then
        cleanup_deployment
        exit 0
    fi
}

set_namespaces()
{
    # If silent Install option is specified and NS is not provided for
    # operator or CTE-K8s, then set it to kube-system
    if [ ${SILENT_INSTALL} -eq 1 ]; then
        if [ -z ${OPR_NS} ]; then
            OPR_NS="kube-system"
        fi

        if [ -z ${CTEK8S_NS} ]; then
	    CTEK8S_NS="kube-system"
        fi
    else
        RESPONSE=""
        if [ -z ${OPR_NS} ]; then
            ${ECHO} -n "Namespace for deploying CipherTrust Transparent Encryption for Kubernetes Operator. Hit ENTER for [kube-system]:"
            read RESPONSE
            if [ "x${RESPONSE}" = "x" ]; then
                OPR_NS="kube-system"
            else
                OPR_NS=${RESPONSE}
            fi
        fi

        RESPONSE=""
        if [ -z ${CTEK8S_NS} ]; then
            ${ECHO} -n "Namespace for deploying CipherTrust Transparent Encryption for Kubernetes CSI driver. Hit ENTER for [kube-system]:"
            read RESPONSE
            if [ "x${RESPONSE}" = "x" ]; then
                CTEK8S_NS="kube-system"
            else
                CTEK8S_NS=${RESPONSE}
            fi
        fi
    fi

    ${OC_KUBECTL_CMD} get ns ${OPR_NS} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        ans="N"
        ${ECHO} -n "Namespace ${OPR_NS} not found. Do you want to create it now?[N/y]:"
        read ans
        if [ "x${ans}" = "xY" ] || [ "x${ans}" = "xy" ]
        then
            ${OC_KUBECTL_CMD} create namespace ${OPR_NS}
            if [ $? -ne 0 ]; then
                ${ECHO} "Error creating namespace: ${OPR_NS}"
                exit 1
            fi
        else
            ${ECHO} "Exiting without creating namespace ${OPR_NS}. Deploy aborted"
            exit 1
	    fi
    fi

    ${OC_KUBECTL_CMD} get ns ${CTEK8S_NS} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        ans="N"
        ${ECHO} -n "Namespace ${CTEK8S_NS} not found. Do you want to create?[N/y]:"
        read ans
        if [ "x${ans}" = "xY" ] || [ "x${ans}" = "xy" ]
        then
            ${OC_KUBECTL_CMD} create namespace ${CTEK8S_NS}
            if [ $? -ne 0 ]; then
                ${ECHO} "Error creating namespace: ${CTEK8S_NS}"
                exit 1;
            fi
        else
            ${ECHO} "Exiting without creating namespace ${CTEK8S_NS}. Deploy aborted"
            exit 1
	    fi
    fi

    ${ECHO} "--------------------------------------------------------------------------"
    ${ECHO} "CipherTrust Transparent Encryption for Kubernetes Operator will be deployed in namespace: ${OPR_NS}"
    ${ECHO} "CipherTrust Transparent Encryption for Kubernetes will be deployed in namespace: ${CTEK8S_NS}"
    ${ECHO} "--------------------------------------------------------------------------"
    sleep 2
}

create_rbac_objects()
{

    # Delete the ServiceAccounts, ClusterRoles and ClusterRoleBindings created by Operator deploy in the Operator NS
    ${OC_KUBECTL_CMD} delete sa cte-csi-controller cte-csi-node -n ${OPR_NS} > /dev/null 2>&1
    ${OC_KUBECTL_CMD} delete ClusterRole cte-csi-controller-ac cte-csi-node-ac > /dev/null 2>&1
    ${OC_KUBECTL_CMD} delete ClusterRoleBinding cte-csi-controller-binding cte-csi-node-binding > /dev/null 2>&1

    # Copy the RBAC manifests from the Helm Chart templates directory.
    cp ${DEPLOY_SCRIPT_PATH}/../templates/rbac*.yaml ${DEPLOY_SCRIPT_PATH}
    # The namespace field is templatized as "namespace: {{ .Values.namespace }}". Replace with user supplied value.
    sed -i s/"namespace: .*"/"namespace: ${CTEK8S_NS}"/g ${DEPLOY_SCRIPT_PATH}/rbac*.yaml

    ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/rbac-cte-csi-controller.yaml -n ${CTEK8S_NS}
    if [ $? -ne 0 ]; then
        ${ECHO} "Error creating RBAC for cte-csi-controller in namespace ${CTEK8S_NS}"
        exit 1
    fi

    ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/rbac-cte-csi-nodeserver.yaml -n ${CTEK8S_NS}
    if [ $? -ne 0 ]; then
        ${ECHO} "Error creating RBAC for cte-csi-node in namespace ${CTEK8S_NS}"
        exit 1
    fi

    # Discard the RBAC manifests copied from the Helm Chart templates directory.
    rm -f ${DEPLOY_SCRIPT_PATH}/rbac-*.yaml

    # if CTE-K8s is not deployed in kube-system NS, then we need to define a Security Context that can be
    # used by the RBAC accounts created above.
    if [ ${IS_OCP} -eq 1 ] && [ "x${CTEK8S_NS}" != "xkube-system" ]
    then
        ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/cte-csi-scc.yaml
        if [ $? -ne 0 ]; then
            ${ECHO} "Error creating SecurityContextConstraints: cte-csi-scc"
            exit 1
        fi
    fi
}

deploy_cte_csi()
{
    if [ ${IS_OCP} -eq 1 ]; then
        VALIDATE=""
        sed -i s/"^  source: .*"/"  source: certified-operators"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml
        sed -i s/"^  sourceNamespace: .*"/"  sourceNamespace: openshift-marketplace"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml
    else
        # some fields in the manifests for Openshift are not yet supported on Kubernetes.
        # Tell kubectl to ignore validation of the manifest if deploying on Kubernetes
        VALIDATE="--validate=false"
        # the catalog for CteK8sOperator is deployed differently on Kubernetes. Adjust the yaml file
#        sed -i s/"^  source: .*"/"  source: operatorhubio-catalog"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml
#        sed -i s/"^  sourceNamespace: .*"/"  sourceNamespace: olm"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml

	# Make catalog source point to our dockerhub image location
	DOCKER_LOC="docker.io/thalesciphertrust/ciphertrust-transparent-encryption-kubernetes-operator-catalog:v1.2.5"
	ESCAPED_DOCKER_LOC=`echo ${DOCKER_LOC} | sed  's#\/#\\\/#g'`
        sed -i s/"^  image: .*"/"  image: ${ESCAPED_DOCKER_LOC}"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-catsrc.yaml

	# Check if cte-k8s-operator is already installed, if found, remove it. It is safe to do so. Does not affect CSI deployment
	IS_OPR_INSTALLED=$(${OC_KUBECTL_CMD} get operators cte-k8s-operator.kube-system 2>/dev/null | wc -l)
	if [ ${IS_OPR_INSTALLED} -eq 2 ]; then
		${OC_KUBECTL_CMD} delete operator cte-k8s-operator.kube-system
	fi
	# Create catalog for our operator from image on dockerhub
	${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-catsrc.yaml

	# Make our subscription point to our custom catalog in the kube-system namespace
        sed -i s/"^  source: .*"/"  source: ctek8soperator-catalog"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml
        sed -i s/"^  sourceNamespace: .*"/"  sourceNamespace: kube-system"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml
    fi

    sed -i s/"namespace: .*"/"namespace: ${OPR_NS}"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml

    ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-operatorgroup.yaml -n ${OPR_NS} ${VALIDATE}
    if [ $? -ne 0 ]; then
        ${ECHO} "Error creating OperatorGroup: ctek8soperator-og"
        exit 1
    fi

    ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml ${VALIDATE}
    if [ $? -ne 0 ]; then
        ${ECHO} "Error creating Subscription: ctek8soperator-sub"
        exit 1
    fi

    ${ECHO} -n "Waiting for InstallPlan to be instantiated and approved."

    loop_ctr=0
    while :
    do
        OPR_STATUS=$(${OC_KUBECTL_CMD} get pods -n ${OPR_NS} 2>/dev/null | awk '/cte-k8s-operator-controller-manager/ { print $3 }')
	if [ "x${OPR_STATUS}" = "xRunning" ] || [ $loop_ctr -eq 60 ]; then
		${ECHO} "."
		break
        # Continue until either 60s have elapsed or status of the controller manager pod has changed to Running
	else
            ${ECHO} -n "."
            sleep 1
	    if [ "x${OPR_STATUS}" != "xRunning" ]; then
                (( loop_ctr++ ))
            fi
	fi
	sleep 1
    done

    if [ "x${OPR_STATUS}" != "xRunning" ] ; then
        OPR_POD=$(${OC_KUBECTL_CMD} get pods -n ${OPR_NS} 2>/dev/null | awk '/cte-k8s-operator-controller-manager/ { print $1 }')
        ${ECHO} "Error installing operator. To check the logs run \n\n\t ${OC_KUBECTL_CMD} logs ${OPR_POD} -n ${OPR_NS}\n"
        exit 1
    fi

    ${ECHO} "Successfully installed CipherTrust Transparent Encryption for Kubernetes Operator"
    ${ECHO} "Deploying CipherTrust Transparent Encryption for Kubernetes"

    # Wait for the ctek8soperator Custom Resource Definition to get registered with K8s, before deploying CTE-CSI.
    ${ECHO} -n "Waiting for the ctek8soperator CRD to get registered with K8s."
    loop_ctr=0
    while :
    do
	${ECHO} -n "."
	${OC_KUBECTL_CMD} api-resources --api-group=cte-k8s-operator.csi.cte.cpl.thalesgroup.com | grep -w CteK8sOperator > /dev/null 2>&1
	if [ $? = 0 ]; then
		break
	fi
	if [ ${loop_ctr} -eq 300 ]; then
		${ECHO} "\nError to get ctek8soperator CRD. Not registered with K8s. Retry Deploying."
		exit 1
	fi
	(( loop_ctr++ ))
	sleep 1
    done
    ${ECHO} "\nSuccessfully registered ctek8soperator CRD with K8s"

    ${ECHO} -n "Waiting for ctek8soperator controller manager to get ready."
    loop_ctr=0
    while :
    do
	${ECHO} -n "."
	${OC_KUBECTL_CMD} get deployment.apps/cte-k8s-operator-controller-manager -n ${OPR_NS} -o yaml | grep -i status | grep -i false > /dev/null 2>&1
	if [ $? = 1 ]; then
		break
	fi
	if [ ${loop_ctr} -eq 120 ]; then
		${ECHO} "\nError ctek8soperator controller manager is not up. Retry Deploying."
		exit 1
	fi
	(( loop_ctr++ ))
	sleep 1
    done
    ${ECHO} "\nctek8soperator controller manager is ready"


    # Update the CRD file with the CRI Socket info that is autodetected
    # Escape the "/" in the sock path so that sed processes it correctly while updating the CRD
    CRISOCK=$(echo ${CRISOCK} | sed  's#\/#\\\/#g')
    sed -i s/"        path: \"\/run.*"/"        path: ${CRISOCK}"/g ${DEPLOY_SCRIPT_PATH}/ctek8soperator-crd.yaml

    ${OC_KUBECTL_CMD} apply -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-crd.yaml -n ${CTEK8S_NS}
    if [ $? -ne 0 ]; then
        ${ECHO} "Error deploying CipherTrust Transparent Encryption for Kubernetes"
        exit 1
    fi

    # Wait for cte-csi pods to get installed
    ${ECHO} -n "Waiting for CipherTrust Transparent Encryption for Kubernetes."
    loop_ctr=0
    while :
    do
	${ECHO} -n "."
	${OC_KUBECTL_CMD} get pods -n ${CTEK8S_NS} 2>/dev/null | grep cte-csi > /dev/null 2>&1
	if [ $? = 0 ] || [ ${loop_ctr} -eq 10 ]; then
		break
	fi
	(( loop_ctr++ ))
	sleep 1
    done

    ${ECHO} "\n=========================================================================================="
    ${ECHO} "CipherTrust Transparent Encryption for Kubernetes Operator deployed in namespace ${OPR_NS}"
    ${ECHO} "CipherTrust Transparent Encryption for Kubernetes in namespace ${CTEK8S_NS}"
    ${OC_KUBECTL_CMD} get pods -n ${CTEK8S_NS} | grep cte-csi
    ${ECHO} "=========================================================================================="
}

cleanup_deployment()
{
    # Bail out if any application is using CTE K8s Volume(s)
    pod_count=$(${OC_KUBECTL_CMD} get pods --all-namespaces | ${GREP} "cte-staging-pod" | wc -l)
    if [ $pod_count -ge 1 ]; then

        ${ECHO} "                    !!! WARNING !!!"
        ${ECHO} "At least one application appears to be using CipherTrust Transparent Encryption for Kubernetes Volume(s). Can not un-install CipherTrust Transparent Encryption for Kubernetes"
        ${ECHO} "                    !!! WARNING !!!"

        exit 1
    fi

    while [ "x${OPR_NS}" = "x" ]; do
        ${ECHO} -n "Namepace in which CipherTrust Transparent Encryption for Kubernetes Operator is deployed: "
        read OPR_NS
    done

    while [ "x${CTEK8S_NS}" = "x" ]; do
        ${ECHO} -n "Namepace in which CipherTrust Transparent Encryption for Kubernetes is deployed: "
        read CTEK8S_NS
    done

    ${ECHO} "=========================================================================================="
    ${ECHO} "Deleting CTE-K8s Operator resources in namespace: ${OPR_NS}"
    ${ECHO} "Deleting CTE-K8s  resources in namespace: ${CTEK8S_NS}"
    ${ECHO} "=========================================================================================="

    ${OC_KUBECTL_CMD} delete cm cte-k8s-config --namespace=${CTEK8S_NS}
    ${OC_KUBECTL_CMD} delete -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-crd.yaml -n ${CTEK8S_NS}
    CSV=$(${OC_KUBECTL_CMD} get subscription ctek8soperator-sub -n ${OPR_NS} -o yaml | ${AWK} '/currentCSV/ {print $2}')
    ${OC_KUBECTL_CMD} delete -f ${DEPLOY_SCRIPT_PATH}/ctek8soperator-subscription.yaml -n ${OPR_NS}
    ${OC_KUBECTL_CMD} delete csv ${CSV} -n ${OPR_NS}
    ${OC_KUBECTL_CMD} delete og ctek8soperator-og -n ${OPR_NS}
    ${OC_KUBECTL_CMD} delete sa cte-k8s-operator-cte-csi-controller cte-k8s-operator-cte-csi-node -n ${OPR_NS}
    ${OC_KUBECTL_CMD} delete sa cte-csi-controller cte-csi-node -n ${CTEK8S_NS}
    ${OC_KUBECTL_CMD} delete ClusterRole cte-csi-controller-ac cte-csi-node-ac
    ${OC_KUBECTL_CMD} delete ClusterRoleBinding cte-csi-controller-binding cte-csi-node-binding
    ${OC_KUBECTL_CMD} delete customresourcedefinition.apiextensions.k8s.io/ctek8soperators.cte-k8s-operator.csi.cte.cpl.thalesgroup.com
    ${OC_KUBECTL_CMD} delete csidriver csi.cte.cpl.thalesgroup.com
    if [ ${IS_OCP} -eq 1 ] && [ "x${CTEK8S_NS}" != "xkube-system" ]
    then
        ${OC_KUBECTL_CMD} delete scc cte-csi-scc
    fi
    ${OC_KUBECTL_CMD} delete clusterrole.rbac.authorization.k8s.io/cte-k8s-operator-metrics-reader >/dev/null 2>&1
    ${OC_KUBECTL_CMD} delete rolebinding cte-k8s-operator-controller-manager-service-auth-reader -n ${CTEK8S_NS} >/dev/null 2>&1
    ${OC_KUBECTL_CMD} delete operator.operators.coreos.com/cte-k8s-operator.${OPR_NS}
}

chk_pkgs
parse_cmdline $@

set_namespaces
create_rbac_objects
deploy_cte_csi
