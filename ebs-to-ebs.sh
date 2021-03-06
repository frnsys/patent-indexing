#!/bin/bash

# Attaches two EBS volumes and merges them to a third

if [ $# -lt 2 ]
then
  echo
  echo "Usage: ebs-to-ebs.sh vol_id1 vol_id2 [vol_id3...]"
  exit 0
fi  

args=("$@")
VOLS=$#
EBS_VOLt=""
EBS_SIZE=""
EC2_INSTANCE_ID="`wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`"
EC2_PRIVATE_KEY=~/.aws_creds/pk-SS5MTCPI5NCLXEBYWAXPLRKQJRXWDPW7.pem
EC2_CERT=~/.aws_creds/cert-SS5MTCPI5NCLXEBYWAXPLRKQJRXWDPW7.pem
export EC2_PRIVATE_KEY EC2_CERT

log() {
    # might do something interesting here, but for now it's good for trimming STDOUT
    echo -e "$@"
}

get_ebs_state() {
    log "** get_ebs_state $@ **"
    ec2-describe-volumes $2 | grep $1 | cut -f 6
}

wait_for_ebs() {
    log "** wait_for_ebs $@ **"
    while [ `get_ebs_state $1 $3 | grep $2 | wc -l` -gt 0 ]
    do
        sleep 15
    done
}

wait_for_device() {
    log "** wait_for_device $@ **"
    # We seem to need to wait a little for the OS to show the volume
    while [ ! -h $1 ]
    do
        sleep 10
    done
}

attach_volumes() {
    log "** attach_volumes $@ **"
    for (( c=0; c<$VOLS; c++ ))
    do
        ec2-attach-volume ${args[$c]} --instance $EC2_INSTANCE_ID --device /dev/sdf$(( $c + 1 ))
    done
    for (( c=1; c<=$VOLS; c++ ))
    do
        wait_for_device /dev/sdf${c}
    done
}

attach_volume() {
    log "** attach_volume $@ **"
    ec2-attach-volume $EBS_VOLt --instance $EC2_INSTANCE_ID --device /dev/sdt
    wait_for_ebs ATTACHMENT attaching $EBS_VOLt
    wait_for_device /dev/sdt
}

create_core() {
    log "** create_core $@ **"
    CURL="http://localhost:8983/solr/admin/cores?wt=json&indent=true&action=CREATE"
    IDIR="instanceDir=/home/ec2-user/patent-indexing/solr/dir_search_cores/us_patent_grant_v2_0/"
    CFILE="config=solrconfig.xml"
    SFILE="schema=schema.xml"
    DDIR="dataDir=/media/ebst/data"
    curl "${CURL}&name=${EC2_INSTANCE_ID}&${IDIR}&${CFILE}&${SFILE}&${DDIR}"
}

merge_to_ebs() {
    log "** merge_to_ebs $@ **"
    CURL="http://localhost:8983/solr/admin/cores?wt=json&indent=true&action=mergeindexes"
    CURL="${CURL}&core=${EC2_INSTANCE_ID}"
    for (( c=1; c<=$VOLS; c++ ))
    do
        CURL="${CURL}&core=${EC2_INSTANCE_ID}&indexDir=/media/ebs$(( $c ))/data/index"
    done
    curl $CURL
}

create_volume() {
    log "** create_volume $@ **"

    for (( c=1; c<=$VOLS; c++ ))
    do
        sudo mkdir -p /media/ebs$(( $c ))
    done

    sudo mkdir -p /media/ebst

    for (( c=1; c<=$VOLS; c++ ))
    do
        sudo mount /dev/sdf${c} /media/ebs${c}
    done

    for (( c=1; c<=$VOLS; c++ ))
    do
        DU=`du -s /media/ebs${c}/data | cut -f 1`
        EBS_SIZE=$(( $EBS_SIZE + $DU ))
    done
    # do some funky math to give us some headway in our new volume
    EBS_SIZE=`echo "((${EBS_SIZE} + 0)*3/2000000)+1" | bc`

    region=`ec2-describe-instances $EC2_INSTANCE_ID | grep INSTANCE | cut -f 12`
    ec2-create-volume --size ${EBS_SIZE} -z $region > ~/ebs-create-log
    echo "** create_volume ${EBS_SIZE} **"
    EBS_VOLt=`tail -n 1 ~/ebs-create-log | grep VOLUME | cut -f 2`
    wait_for_ebs VOLUME creating $EBS_VOLt

    attach_volume    
    
    sudo mkfs.ext4 /dev/sdt > /dev/null
    sudo mkdir -p /media/ebst
    sudo mount /dev/sdt /media/ebst
    sudo mkdir /media/ebst/data
    sudo chown ec2-user:ec2-user /media/ebst/data
}

unmount_detach() {
    log "** unmount_detach $@ **"
    for (( c=1; c<=$VOLS; c++ ))
    do
        sudo umount /dev/sdf$(( $c ))
    done
    sudo umount /dev/sdt

    
    for (( c=0; c<$VOLS; c++ ))
    do
        ec2-detach-volume ${args[$c]}
    done
    ec2-detach-volume $EBS_VOLt

    for (( c=0; c<$VOLS; c++ ))
    do
        wait_for_ebs ATTACHMENT detaching ${args[$c]}
    done
    wait_for_ebs ATTACHMENT detaching $EBS_VOLt
}

sudo service jetty start
attach_volumes
create_volume

log "EBSSize:${EBS_SIZE} NewEBS:${EBS_VOLt}"

create_core
merge_to_ebs
sudo service jetty stop
(cd ~/patent-indexing; git checkout solr/dir_search_cores/solr.xml)
unmount_detach
