#!/usr/bin/env bash

set -o errexit
set -o nounset

# Kill entire process group
trap 'kill -- -$$' SIGINT

TOP_DIR=$(cd "$(dirname "$0")" && pwd)

: ${DISTRO:=ubuntu-14.04-server-amd64}
: ${PROVIDER:=virtualbox}

source "$TOP_DIR/config/localrc"
source "$TOP_DIR/config/paths"
source "$CONFIG_DIR/openstack"
source "$CONFIG_DIR/deploy.osbash"
source "$CONFIG_DIR/provider.$PROVIDER"
source "$OSBASH_LIB_DIR/lib.$DISTRO"
source "$OSBASH_LIB_DIR/functions-host.sh"
source "$OSBASH_LIB_DIR/$PROVIDER-functions.sh"
source "$OSBASH_LIB_DIR/$PROVIDER-install_base.sh"
source "$LIB_DIR/osbash/lib-color.sh"

function usage {
    echo "Usage: $0 {-b|-w} [-g GUI] [--no-color] [-n] [-t SNAP] {TARGET}"
    # Don't advertise export until it is working properly
    # echo "       $0 [-e EXPORT] [-n] NODE [NODE..]"
    echo
    echo "-h|--help  Help"
    echo "-n         Print configuration status and exit"
    echo "-b         Build basedisk (if necessary) and node VMs (if any)"

    # Don't use -t directly, have tools/repeat-test.sh call it
    #echo "-t SNAP    Jump to snapshot SNAP and continue build"

    echo "-w         Create Windows batch files"
    echo "-g GUI     GUI type during build"
    #echo "-e EXPORT Export node VMs"
    echo "--no-color Disables colors during build"
    echo
    echo "TARGET     basedisk: build configured basedisk"
    echo "           cluster : build OpenStack cluster [all nodes]"
    echo "                     (and basedisk if necessary)"
    echo "GUI        gui, sdl, or headless (GUI type for VirtualBox)"

    # Don't use -t SNAP directly, have tools/repeat-test.sh call it
    #echo "SNAP       Name of snapshot from which build continues"

    #echo "EXPORT    ova (OVA package file) or dir (VM clone directory)"
    exit
}

function print_config {
    local basedisk=$(get_base_disk_name)
    if [ "$CMD" = "basedisk" ]; then
        echo -e "${CInfo:-}Target is base disk:${CData:-} $basedisk${CReset:-}"
    else
        echo -e "${CInfo:-}Base disk:${CData:-} $basedisk${CReset:-}"
        echo -e "${CInfo:-}Distribution name: ${CData:-} $(get_distro_name "$DISTRO")${CReset:-}"
    fi

    if [ -n "${EXPORT_OVA:-}" ]; then
        echo "Exporting to OVA: ${EXPORT_OVA}"
    elif [ -n "${EXPORT_VM_DIR:-}" ]; then
        echo "Exporting to directory: ${EXPORT_VM_DIR}"
    else
        echo -e -n "${CInfo:-}Creating Windows batch scripts:${CReset:-} "
        ${WBATCH:-:} echo -e "${CData:-}yes${CReset:-}"
        ${WBATCH:+:} echo -e "${CData:-}no${CReset:-}"

        echo -e -n "${CInfo:-}Creating $CMD on this machine:${CReset:-} "
        ${OSBASH:-:} echo -e "${CData:-}yes${CReset:-}"
        ${OSBASH:+:} echo -e "${CData:-}no${CReset:-}"

        echo -e "${CInfo:-}VM access method:${CData:-} $VM_ACCESS${CReset:-}"

        # GUI is the VirtualBox default
        echo -e "${CInfo:-}GUI type:${CData:-} ${VM_UI:-gui}${CReset:-}"

        if [ -n "${JUMP_SNAPSHOT:-}" ]; then
            echo -e "${CInfo:-}Continuing from snapshot:" \
                    "${CData:-}${JUMP_SNAPSHOT}${CReset:-}"
        fi
    fi

}

while getopts :be:g:-:hnt:w opt; do
    case $opt in
        e)
            if [ "$OPTARG" = ova ]; then
                EXPORT_OVA=$IMG_DIR/labs-$DISTRO.ova
            elif [ "$OPTARG" = dir ]; then
                EXPORT_VM_DIR=$IMG_DIR/labs-$DISTRO
            else
                echo -e "${CError:-}Error: -e argument must be ova or dir${CReset:-}"
                exit
            fi
            OSBASH=exec_cmd
            ;;
        b)
            OSBASH=exec_cmd
            ;;
        g)
            if [[ "$OPTARG" =~ (headless|gui|sdl) ]]; then
                VM_UI=$OPTARG
            else
                echo -e "${CError:-}Error: -g argument must be gui, sdl, or headless${CReset:-}"
                exit
            fi
            ;;
        -)
            case $OPTARG in
                no-color)
                    unset CError CStatus CInfo CProcess CData CMissing CReset
                    ;;
                help)
                    usage
                    ;;
                *)
                    echo -e "${CError:-}Error: invalid option -$OPTARG${CReset:-}"
                    echo
                    usage
                    ;;
            esac
            ;;
        h)
            usage
            ;;
        n)
            INFO_ONLY=1
            ;;
        t)
            JUMP_SNAPSHOT=$OPTARG
            ;;
        w)
            source "$LIB_DIR/wbatch/batch_for_windows.sh"
            ;;
        :)
            echo -e "${CError:-}Error: -$OPTARG needs argument${CReset:-}"
            ;;
        ?)
            echo -e "${CError:-}Error: invalid option -$OPTARG${CReset:-}"
            echo
            usage
            ;;
    esac
done

# Remove processed options from arguments
shift $(( OPTIND - 1 ));

if [ $# -eq 0 ]; then
    # No argument given
    usage
else
    CMD=$1
fi

# Install over ssh by default
: ${VM_ACCESS:=ssh}

print_config

if [ "${INFO_ONLY:-0}" -eq 1 ]; then
    exit
fi

# Clean wbatch directory
${WBATCH:-:} wbatch_reset

if [ -n "${EXPORT_OVA:-}" ]; then
    vm_export_ova "$EXPORT_OVA" "$nodes"
    exit
fi

if [ -n "${EXPORT_VM_DIR:-}" ]; then
    vm_export_dir "$EXPORT_VM_DIR" "$nodes"
    exit
fi

if [ -z "${OSBASH:-}" -a -z "${WBATCH:-}" ]; then
    echo
    echo -e "${CMissing:-}No -b, -w, or -e option given. Exiting.${CReset:-}"
    exit
fi

STARTTIME=$(date +%s)
echo -e >&2 "${CStatus:-} $(date) osbash starting ${CReset:-}"

clean_dir "$LOG_DIR"

function check_existing_base_disk {
    if [ "$CMD" = basedisk ]; then
        if base_disk_exists; then

            echo >&2 "Found existing base disk: $(get_base_disk_name)"

            if ! yes_or_no "Keep this base disk?"; then
                base_disk_delete
            else
                echo -e >&2 "${CMissing:-}Nothing to do. Exiting.${CReset:-}"
                exit
            fi
        fi
    fi
}

${OSBASH:-:} check_existing_base_disk

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
if ! base_disk_exists; then
    echo -e >&2 "${CStatus:-}Creating basedisk.${CReset:-}"
    vm_install_base
else
    echo -e >&2 "${CStatus:-}basedisk already exists.${CReset:-}"
    # Leave base disk alone, but call the function if wbatch is active
    OSBASH= ${WBATCH:-:} vm_install_base
fi
#-------------------------------------------------------------------------------
if [ "$CMD" = basedisk ]; then
    exit
fi

echo "Building nodes using base disk $(get_base_disk_name)"

${WBATCH:-:} wbatch_create_hostnet
MGMT_NET_IF=$(create_network "MGMT_NET")
TUNNEL_NET_IF=$(create_network "TUNNEL_NET")
API_NET_IF=$(create_network "API_NET")
#-------------------------------------------------------------------------------
source "$OSBASH_LIB_DIR/$PROVIDER-install_nodes.sh"
vm_build_nodes "$CMD"
#-------------------------------------------------------------------------------
ENDTIME=$(date +%s)
echo -e >&2 "${CStatus:-}$(date) osbash finished successfully${CReset:-}"
echo -e >&2 "${CStatus:-}osbash completed in $(($ENDTIME - $STARTTIME))" \
            "seconds.${CReset:-}"