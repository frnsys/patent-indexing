#!/bin/bash

# Creates an EBS volume and merges two indexes together

EC2_INSTANCE_ID="`wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`"
INDEX1_SIZE=`du -s /media/ephemeral0/data | cut -f 1`
INDEX2_SIZE=`du -s /media/ephemeral1/data | cut -f 1`
# do some funky math to give us some headway in our new volume
EBS_SIZE=`echo "((${INDEX1_SIZE} + ${INDEX2_SIZE})*3/2000000)+1" | bc`
EBS_VOL=""
EC2_PRIVATE_KEY=~/.aws_creds/pk-SS5MTCPI5NCLXEBYWAXPLRKQJRXWDPW7.pem
EC2_CERT=~/.aws_creds/cert-SS5MTCPI5NCLXEBYWAXPLRKQJRXWDPW7.pem
export EC2_PRIVATE_KEY EC2_CERT

log() {
    # might do something interesting here, but for now it's good for trimming STDOUT
    if [ "$LOGGING" == "false" ]; then
        echo -e $@
    else
        echo -e $@ >> ~/${EC2_INSTANCE_ID}.out
    fi
}

get_ebs_state() {
    EBS_VOL=`cat ~/ebs-create-log | grep $1 | cut -f 2`
    ec2-describe-volumes $EBS_VOL | grep $1 | cut -f 6
}

wait_for_ebs() {
    while [ `get_ebs_state $1 | grep $2 | wc -l` -gt 0 ]
    do
        sleep 15
    done
}

attach_volume() {
    vol=`cat ~/ebs-create-log | grep VOLUME | cut -f 2`
    ec2-attach-volume $vol --instance $EC2_INSTANCE_ID --device /dev/sdf
    wait_for_ebs ATTACHMENT attaching
    while [ ! -h /dev/sdf ]
    do
        sleep 10
    done
}

create_core() {
    CURL="http://localhost:8983/solr/admin/cores?action=CREATE"
    IDIR="instanceDir=/home/ec2-user/patent-indexing/solr/dir_search_cores/us_patent_grant_v2_0/"
    CFILE="config=solrconfig.xml"
    SFILE="schema=schema.xml"
    DDIR="dataDir=/media/ebs/data"
    curl "${CURL}&name=${EC2_INSTANCE_ID}&${IDIR}&${CFILE}&${SFILE}&${DDIR}"
}

merge_to_ebs() {
    CURL="http://localhost:8983/solr/admin/cores?action=mergeindexes"
    CORE="core=${EC2_INSTANCE_ID}"
    DIR1="indexDir=/media/ephemeral0/data/index"
    DIR2="indexDir=/media/ephemeral1/data/index"
    curl "${CURL}&${CORE}&${DIR1}&${DIR2}"
}

create_ebs() {
    region=`ec2-describe-instances $EC2_INSTANCE_ID | grep INSTANCE | cut -f 12`
    ec2-create-volume --size ${EBS_SIZE} -z $region >> ~/ebs-create-log
    wait_for_ebs VOLUME creating
}

ready_mount() {
    sudo mkfs.ext4 /dev/sdf
    sudo mkdir -p /media/ebs
    sudo mount /dev/sdf /media/ebs
    sudo mkdir /media/ebs/data
    sudo chown ec2-user:ec2-user /media/ebs/data
}

log "Index1:${INDEX1_SIZE} Index2:${INDEX2_SIZE} EBS:${EBS_SIZE} VOL:${EBS_VOL}"

create_ebs
attach_volume
ready_mount
create_core
merge_to_ebs
