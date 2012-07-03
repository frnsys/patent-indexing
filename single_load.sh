#!/bin/bash

if [ $# -lt 1 ]
then
  echo
  echo "Usage: single_load.sh patent_grant_url"
  exit 0
fi  

START=$(date +%s)
EC2_INSTANCE_ID="`wget -q -O - http://169.254.169.254/latest/meta-data/instance-id`"
SCRIPT_DIR=${SCRIPT_DIR:-~/patent-indexing}

# Unzip categories.zip if necessary
if [ ! -f ${SCRIPT_DIR}/categories.xml ] ; then
    pushd ${SCRIPT_DIR}
    unzip categories.zip
    popd
fi

url=$1

if [ -f /tmp/using.ephemeral0 ] ; then
    if [ -f /tmp/using.ephemeral ] ; then
        echo "I don't know how to handle more than two indexes" >&2
        exit 1
    else
        touch /tmp/using.ephemeral
        data_dir=/media/ephemeral1/data
    fi
else
    touch /tmp/using.ephemeral0
    data_dir=/media/ephemeral0/data
fi


file=`echo ${url} | awk -F '/' '{print $7}'`
filebase=`echo ${file} | awk -F '.' '{print $1}'`
test ! -d $filebase && mkdir $filebase
ln -s ${SCRIPT_DIR}/categories.xml ${filebase}/categories.xml
ln -s ${SCRIPT_DIR}/saxon9he.jar ${filebase}/saxon9he.jar
ln -s ${SCRIPT_DIR}/convert.xsl ${filebase}/convert.xsl
ln -s ${SCRIPT_DIR}/cals_table.xsl ${filebase}/cals_table.xsl
(
    cd $filebase
    if [ ! -f $file ]
    then
        wget -q ${url} -o wget.log
        ${SCRIPT_DIR}/fix-zip-filenames.sh
        #echo ${file}
        ZIP_SIZE=`du -h ${file} | cut -f 1`
        unzip ${file}
    fi

    if [ ! -f ${filebase}.json ]
    then
        ${SCRIPT_DIR}/convert.sh ${filebase}.xml ${filebase}.json >> ~/${EC2_INSTANCE_ID}.${filebase}.convert.log 2>&1
    fi
    
    CURL="http://localhost:8983/solr/admin/cores?action=CREATE"
    IDIR="instanceDir=/home/ec2-user/patent-indexing/solr/dir_search_cores/us_patent_grant_v2_0/"
    CFILE="config=solrconfig.xml"
    SFILE="schema=schema.xml"
    DDIR="dataDir=${data_dir}"
    curl "${CURL}&name=${filebase}&${IDIR}&${CFILE}&${SFILE}&${DDIR}"

    INDEX_SIZE=`du -sh ${data_dir} | cut -f 1`
    (export SOLR_CORE=${filebase}; ${SCRIPT_DIR}/post_json.sh ${filebase}.json >> ~/${EC2_INSTANCE_ID}.${filebase}.post.log 2>&1)
    #####rm -f ${file}.json ${filebase}.xml ${file}

    END=$(date +%s)
    DIFF=$(( $END - $START ))

    echo -e "${EC2_INSTANCE_ID}\t${file}\t${ZIP_SIZE}\t${INDEX_SIZE}\t${DIFF}" >> ~/${EC2_INSTANCE_ID}.out
    #	Ordinal
)
