#!/usr/bin/env bash

# This script will map USB devices to a specific VM
# Written by Ez-Aton, http://run.tournament.org.il , with the concepts
# taken from http://jamesscanlonitkb.wordpress.com/2012/03/11/xenserver-mount-usb-from-host/
# and http://support.citrix.com/article/CTX118198

# Variables
# Need to change them to match your own!
REMOVABLE_SR_UUID=3914aaf7-8675-fa5d-684b-6654f43984b9 # xe sr-list name-label=Removable\ Storage
VM_UUID=b9ba16a8-22c2-f612-15b7-54de97dc3329 # xe vm-list; 'UVB' on 'smartsystems-host'
DEVICE_NAMES="sde sdf" # Local disk mappings for the host VM; 'smartsystems-host'
XE=/opt/xensource/bin/xe

function attach() {
        # Here we attach the disks
        # Check if storage is attached to VBD
        VBDS=`$XE vdi-list sr-uuid=${REMOVABLE_SR_UUID} params=vbd-uuids --minimal | tr , ' '`
        #VBDS=`/opt/xensource/bin/xe vdi-list sr-uuid=3914aaf7-8675-fa5d-684b-6654f43984b9 params=vbd-uuids --minimal | tr , ' '`
        if [ `echo $VBDS | wc -w` -ne 0 ]
        then
                echo "Disks are already attached. Check VBD $VBDS for details"
                exit 1
        fi
        # Get devices!
        VDIS=`$XE vdi-list sr-uuid=${REMOVABLE_SR_UUID} --minimal | tr , ' '`
        INDEX=0
        DEVICE_NAMES=( $DEVICE_NAMES )
        for i in $VDIS
        do
                VBD=`$XE vbd-create vm-uuid=${VM_UUID} device=${DEVICE_NAMES[$INDEX]} vdi-uuid=${i}`
                if [ $? -ne 0 ]
                then
                        echo "Failed to connect $i to ${DEVICE_NAMES[$INDEX]}"
                        exit 2
                fi
                $XE vbd-plug uuid=$VBD
                if [ $? -ne 0 ]
                then
                        echo "Failed to plug $VBD"
                        exit 3
                fi
                let INDEX++
        done
}

function detach() {
        # Here we detach the disks
        VBDS=`$XE vdi-list sr-uuid=${REMOVABLE_SR_UUID} params=vbd-uuids --minimal | tr , ' '`
        for i in $VBDS
        do
                $XE vbd-unplug uuid=${i}
                $XE vbd-destroy uuid=${i}
        done
        echo "Storage detached from VM"
}
case "$1" in
        attach) attach
                ;;
        detach) detach
                ;;
        *)      echo "Usage: $0 [attach|detach]"
                exit 1
esac
