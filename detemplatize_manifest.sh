#!/bin/bash

#Check if helm command is installed
type helm > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo "This script requires the helm command. Please install helm to proceed further"
    exit 1
fi

# ---------------------------------------------------------------------------
# Optional flags:
#   -i | --image  <image>   Override cteCsiImage in values.yaml before rendering.
#   -t | --tag    <tag>     Override cteCsiTag in values.yaml before rendering.
#
# VERSION-AWARE PATCHING (when -t is given):
#   The tag's MAJOR.MINOR (2.0, 1.7 )prefix is extracted and matched against the version
#   directory name. Only the matching version dir's values.yaml is patched.
#   All other version dirs use their own values.yaml defaults unchanged.
#   If -i is given without -t, the image override is applied to ALL version dirs.
CUSTOM_IMAGE=""
CUSTOM_TAG=""

usage() {
    echo "Usage: $0 [-i|--image <image>] [-t|--tag <tag>]"
    echo ""
    echo "  -i | --image <image>   Override cteCsiImage in values.yaml"
    echo "                         Default: value already in values.yaml (docker.io/thalesciphertrust/...)"
    echo "  -t | --tag   <tag>     Override cteCsiTag in values.yaml"
}

# Parse arguments
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--image)
            CUSTOM_IMAGE="$2"
            shift 2
            ;;
        -t|--tag)
            CUSTOM_TAG="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# patch only the version dir(s) whose MAJOR.MINOR matches the tag.
# If no tag is given but an image is given, patch all version dirs.
# ---------------------------------------------------------------------------
PATCHED_FILES=""

if [ -n "${CUSTOM_IMAGE}" ] || [ -n "${CUSTOM_TAG}" ]; then

    # Extract MAJOR.MINOR from tag (e.g. "1.7.0-latest" -> "1.7")
    TAG_MAJOR_MINOR=""
    if [ -n "${CUSTOM_TAG}" ]; then
        TAG_MAJOR_MINOR=$(echo "${CUSTOM_TAG}" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
    fi

    for VERS in $(ls -1 deploy/kubernetes/ | grep -v latest); do
        VALUES_FILE="deploy/kubernetes/${VERS}/values.yaml"

        # Decide whether this version dir should be patched:
        #   - tag given  -> only dirs whose name starts with TAG_MAJOR_MINOR
        #   - image only -> all dirs
        SHOULD_PATCH=0
        if [ -n "${CUSTOM_TAG}" ]; then
            echo "${VERS}" | grep -q "^${TAG_MAJOR_MINOR}\." && SHOULD_PATCH=1
        else
            SHOULD_PATCH=1   # image-only: patch all
        fi

        if [ "${SHOULD_PATCH}" -eq 1 ]; then
            cp "${VALUES_FILE}" "${VALUES_FILE}.orig"
            PATCHED_FILES="${PATCHED_FILES} ${VALUES_FILE}"

            if [ -n "${CUSTOM_IMAGE}" ]; then
                sed -i "s#^\(\s*cteCsiImage:\s*\).*#\1\"${CUSTOM_IMAGE}\"#" "${VALUES_FILE}"
                echo "  [detemplatize] ${VERS}: cteCsiImage -> ${CUSTOM_IMAGE}"
            fi
            if [ -n "${CUSTOM_TAG}" ]; then
                sed -i "s#^\(\s*cteCsiTag:\s*\).*#\1\"${CUSTOM_TAG}\"#" "${VALUES_FILE}"
                echo "  [detemplatize] ${VERS}: cteCsiTag   -> ${CUSTOM_TAG}"
            fi
        fi
    done
fi

# ---------------------------------------------------------------------------
# MAIN LOOP: run helm template for every version dir. Each dir reads its own values.yaml — only the patched one(s) have overrides.
# ---------------------------------------------------------------------------
TMPL_FILE=detemplatized_manifests.yaml
for VERS in `ls -1 deploy/kubernetes/ | grep -v latest`
do
    VALUES_FILE="deploy/kubernetes/${VERS}/values.yaml"

    # For versions >= 2.0.0, COS resources are gated behind the 'cos.enabled' Helm value which defaults to false in values.yaml.
    # enable it so that helm template renders the COS Deployment manifest.
    MAJOR=$(echo ${VERS} | cut -d. -f1)
    if [ "${MAJOR}" -ge 2 ]; then
        helm template cte-tmpl deploy/kubernetes/${VERS} --set cos.enabled=true > ${TMPL_FILE}
    else
        helm template cte-tmpl deploy/kubernetes/${VERS} > ${TMPL_FILE}
    fi
    if [ $? -ne 0 ]; then
        echo "Error encountered running the 'helm template' command"
        exit 1
    fi

    # Everything is returned in one big file, split the files into individual manifests
    j=$(grep -c -- "---" ${TMPL_FILE})    # Number of manifests in the generated yaml file
    k=$((${j}-1))                         # Number of splits to perform
    csplit -f cte-csi-csplit_ ${TMPL_FILE} /---/ {${k}} > /dev/null

    # The first file in our case is always empty as the TMPL_FILE starts with ---, discard it
    rm cte-csi-csplit_00

    #rename each of the manifest file to match the existing names in the cte-k8s-operator repo
    for i in $(ls ./cte-csi-csplit_*)
    do
        NAME=$(awk '/Source/ { printf $NF }' $i | xargs basename | sed -e s/rbac-//g)
        KIND=$(awk '/^kind:/ { printf $NF }' $i)

        case ${KIND} in
            ServiceAccount)
                KIND=sa
                # rename xyz.yaml as xyz-sa.yaml
                NAME=$(echo ${NAME} | sed -e s/.yaml/\-${KIND}.yaml/g)
                sed -i '/^  namespace: .*/d' $i
                ;;
            ClusterRole)
                KIND=role
                # rename xyz.yaml as xyz-role.yaml
                NAME=$(echo ${NAME} | sed -e s/.yaml/\-${KIND}.yaml/g)
                ;;
            ClusterRoleBinding)
                KIND=role-binding
                # rename xyz.yaml as xyz-role-binding.yaml
                NAME=$(echo ${NAME} | sed -e s/.yaml/\-${KIND}.yaml/g)
                ;;
            CSIDriver)
                NAME=cte-csi-csidriver.yaml
                ;;
            ConfigMap)
                NAME=cte-k8s-config.yaml
                 ;;
            CustomResourceDefinition)
                # COS CRD (cmregistrationclasses.thalesgroup.com) has no user-customizable
                # fields — it is pure schema. It is applied by operator-deploy/deploy.sh  Discard it here.
                rm -f ${i}
                continue
                ;;
        esac

        # Remove unwanted lines from the file
        sed -i '/^---/d' $i
        sed -i '/^# Source: /d' $i

        mkdir -p custom_manifests/${VERS}
        # Move the generated and renamed manifests to the appropriate staging dir for packaging
        case ${KIND} in
            sa|role|role-binding)
                #mv ${i} ${OPR_DIR}/config/rbac/${NAME}
                ;;
            *)
                mv ${i} custom_manifests/${VERS}/${NAME}
                ;;
        esac
    done

    # Remove files generated by csplit and the detemplatized manifest file generated earlier
    rm -f cte-csi-csplit_* ${TMPL_FILE}
done

# ---------------------------------------------------------------------------
# POST-LOOP: restore any patched values.yaml files to their original state.
# ---------------------------------------------------------------------------
for VF in ${PATCHED_FILES}; do
    if [ -f "${VF}.orig" ]; then
        mv -f "${VF}.orig" "${VF}"
        #echo "  [detemplatize] restored: ${VF}"
    fi
done
