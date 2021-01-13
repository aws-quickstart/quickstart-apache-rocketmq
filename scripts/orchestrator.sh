#!/bin/bash


# Install jq to parse meta-data
# MISC=/home/ec2-user/misc/bin/
# mkdir -p ${MISC}
JQ_COMMAND=jq
# [ ! -e ${JQ_COMMAND} ] && wget http://stedolan.github.io/jq/download/linux64/jq -O ${JQ_COMMAND}
# chmod 755 ${JQ_COMMAND}
# sudo yum -y install jq

# export PATH=${PATH}:/sbin:/usr/sbin:/usr/local/sbin:/root/bin:/usr/local/bin:/usr/bin:/bin:/usr/bin/X11:/usr/X11R6/bin:/usr/games:/usr/lib/AmazonEC2/ec2-api-tools/bin:/usr/lib/AmazonEC2/ec2-ami-tools/bin:/usr/lib/mit/bin:/usr/lib/mit/sbin:${MISC}


# ---------------------------------------------------------------------
#          env vars to configure aws cli on Amazon Linux
#          No need for keys etc if run on instance with correct IAM role
# ---------------------------------------------------------------------


export AWS_DEFAULT_REGION=${REGION}
export AWS_DEFAULT_AVAILABILITY_ZONE=${AVAILABILITY_ZONE}

if [ -z ${AWS_DEFAULT_REGION} ]; then
   export AWS_DEFAULT_REGION=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
          | ${JQ_COMMAND} '.region'  \
          | sed 's/^"\(.*\)"$/\1/' )
fi
if [ -z ${AWS_DEFAULT_AVAILABILITY_ZONE} ]; then
   export AWS_DEFAULT_AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
            | ${JQ_COMMAND} '.availabilityZone' \
            | sed 's/^"\(.*\)"$/\1/' )
fi

if [ -z ${AWS_INSTANCEID} ]; then
   export AWS_INSTANCEID=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
            | ${JQ_COMMAND} '.instanceId' \
            | sed 's/^"\(.*\)"$/\1/' )
fi

# ------------------------------------------------------------------
#          remove double quotes, if any. cli doesn't like it!
# ------------------------------------------------------------------

export AWS_DEFAULT_REGION=$(echo ${AWS_DEFAULT_REGION} | sed 's/^"\(.*\)"$/\1/' )
export AWS_DEFAULT_AVAILABILITY_ZONE=$(echo ${AWS_DEFAULT_AVAILABILITY_ZONE} | sed 's/^"\(.*\)"$/\1/' )
export AWS_INSTANCEID=$(echo ${AWS_INSTANCEID} | sed 's/^"\(.*\)"$/\1/' )
export AWS_CMD=/usr/bin/aws

MYSTACKID=$(${AWS_CMD} ec2 describe-tags --filters "Name=resource-id,Values=${AWS_INSTANCEID}" | ${JQ_COMMAND} '.Tags[] | select(.Key=="aws:cloudformation:stack-id") | .Value')
MYSTACKID=$(echo ${MYSTACKID} | sed 's/^"\(.*\)"$/\1/' )
MYSTACKPARENT=$(echo ${MYSTACKID} | awk -F '/' '{print $2}' | awk -F'-' '{print $1}')

MYPRIVATEIP=$(curl -s http://169.254.169.254/latest/dynamic/instance-identity/document \
            | ${JQ_COMMAND} '.privateIp' \
            | sed 's/^"\(.*\)"$/\1/' )


log() {
  echo $* 2>&1
}

usage() {
    cat <<EOF
    Usage: $0 [options]
        -h print usage
        -c Create DyanamoDB Table
        -b Block until table is created
        -d Delete table
        -s Update "Status" column
        -u Insert/Update Item (key=value pair)
        -n Table Name (optional. Default name is CFN stackname)
        -q Query number of nodes in a given state
        -w Wait until N nodes reach a specific state (COMPLETE=N)
        -p Print Table
        -g Print IPv4 Adrresses
        -x Print index number
        -y Print all node name and port
        -z NodeType
EOF
#    exit 0
}



# ------------------------------------------------------------------
#          Read all inputs
# ------------------------------------------------------------------


CREATE=0
PRINT=0
BLOCK_UNTIL_TABLE_LIVE=0
DELETE_TABLE=0
GET_IPv4=0
CREATE_KEY=0
FETCH_KEY=0
GET_INDEX=0
GET_ALLNODE=0
INDEX=0

[[ $# -eq 0 ]] && usage;

while getopts "xhcbpdikfs:u:n:q:z:w:y:g:" o; do
  case "${o}" in
    h) usage && exit 0
    ;;
    c) CREATE=1
    ;;
    p) PRINT=1
    ;;
    b) BLOCK_UNTIL_TABLE_LIVE=1
    ;;
    d) DELETE_TABLE=1
    ;;
    g) GET_IPv4=${OPTARG}
    ;;
    q) QUERY_STATUS=${OPTARG}
    ;;
    s) NEW_STATUS=${OPTARG}
    ;;
    k) CREATE_KEY=1
    ;;
    f) FETCH_KEY=1
    ;;
    u) NEW_ITEM_PAIR=${OPTARG}
    ;;
    n) TABLE_NAME=${OPTARG}
    ;;
    z) NODETYPE=${OPTARG}
    ;;
    w) WAIT_STATUS_COUNT_PAIR=${OPTARG}
    ;;
    i) INIT_ENV=1
    ;;
    x) GET_INDEX=1
    ;;
    y) GET_ALLNODE=${OPTARG}
    ;;	    
  esac
done

# ------------------------------------------------------------------
#          Make sure all input parameters are filled
# ------------------------------------------------------------------

shift $((OPTIND-1))
[[ $# -gt 0 ]] && usage;

if [ -z ${TABLE_NAME} ]; then
  export TABLE_NAME=${MYSTACKPARENT}-DDB-Table
  echo "Table name not specified. Using ${TABLE_NAME}"
fi



# ------------------------------------------------------------------
#          Status of Table creation
# ------------------------------------------------------------------

GetCreationStatus() {
    status=$(${AWS_CMD} dynamodb describe-table --table-name ${TABLE_NAME} --query Table.TableStatus)
    echo $status
}

# ------------------------------------------------------------------
#          Wait until Table is created and Active
# ------------------------------------------------------------------

WaitUntilTableActive() {
    while true; do
    status=$(GetCreationStatus)
    log "${TABLE_NAME}:${status}"
    log ${status}
        case "$status" in
          *ACTIVE* ) break;;
        esac
    sleep 10
    done
}


IfTableFound() {
  status=$(${AWS_CMD} dynamodb describe-table --table-name ${TABLE_NAME} 2>&1)
  [[ ${status} == *"not found"* ]] && echo 0 && return
  echo 1
}


# ------------------------------------------------------------------
#  Used in multinode scenario when master created the table
#	 Worker nodes will just wait until table is ready
# ------------------------------------------------------------------

WaitUntilTableLive() {
    while true; do
    status=$(IfTableFound)
    if [ $status -eq 0 ]; then
      echo "Waiting for Master to create table.."
      sleep 10
    else
      echo "Master has created table!"
      break
    fi
  done
}


# ------------------------------------------------------------------
#          Create dynamodb table to do handshake of multinodes
#          Remember you can add other columns anytime!
# ------------------------------------------------------------------

CreateTable() {
  log "CreateTable ${TABLE_NAME}..."
    ${AWS_CMD} dynamodb create-table \
        --table-name ${TABLE_NAME} \
        --attribute-definitions \
            AttributeName=PrivateIpAddress,AttributeType=S \
        --key-schema \
            AttributeName=PrivateIpAddress,KeyType=HASH \
        --provisioned-throughput ReadCapacityUnits=1,WriteCapacityUnits=1

    log "Waiting for table creation"
    WaitUntilTableActive
    log "DynamoDB Table: ${TABLE_NAME} Ready!"
}



# ------------------------------------------------------------------
#          Delete table to make a clean start deploy
# ------------------------------------------------------------------

DeleteTable() {
  status=$(IfTableFound)
  if [ $status -eq 0 ]; then
    echo "Table doesn't exist. No need to delete"
    return
  fi
  status=$(${AWS_CMD} dynamodb delete-table --table-name ${TABLE_NAME})
  WaitUntilTableDead
}

# ------------------------------------------------------------------
#    Wait until table is fully deleted!
# ------------------------------------------------------------------

WaitUntilTableDead() {
    while true; do
        status=$(IfTableFound)
    if [ $status -eq 1 ]; then
      echo "Waiting for table delete to complete!.."
      sleep 10
    else
      echo "Master has deleted table!"
      break
    fi
  done
}


# ------------------------------------------------------------------
#          Initialize the dynamodb table
#          PrivateIpAddress, Status and InstanceId columns init
# ------------------------------------------------------------------

InitMyTable() {
    myip=${MYPRIVATEIP}
    json_template='{ "PrivateIpAddress": {"S": "myip" }}'
    json=$(echo ${json_template} | sed "s/myip/${myip}/g")
    ${AWS_CMD} dynamodb put-item --table-name ${TABLE_NAME}  --item "${json}"
    instanceid=$(curl http://169.254.169.254/latest/meta-data/instance-id)
    InsertMyKeyValueS "InstanceId=${instanceid}"
}




# ------------------------------------------------------------------
#          Update or insert table item with new key=value pair
#          New attributes get added, old attributes get updated
#          Use private ip as primary hash key
#          Usage InsertMyKeyValueS key=value
# ------------------------------------------------------------------

InsertMyKeyValueS() {

    keyvalue=$1
    if [ -z "$keyvalue" ]; then
        echo "Invalid KeyPair Values!"
        return
    fi
    key=$(echo $keyvalue | awk -F'=' '{print $1}')
    value=$(echo $keyvalue | awk -F'=' '{print $2}')

    keyjson_template='{"PrivateIpAddress": {
        "S": "myip"
        }}'
    myip=${MYPRIVATEIP}
    keyjson=$(echo -n ${keyjson_template} | sed "s/myip/${myip}/g")

    insertjson_template='{"key": {
                "Value": {
                    "S": "value"
                },
                "Action": "PUT"
            }
        }'

    insertjson=$(echo -n ${insertjson_template} | sed "s/key/${key}/g")
    insertjson=$(echo -n ${insertjson} | sed "s/value/${value}/g")
    cmd=$(echo  "${AWS_CMD} dynamodb update-item --table-name ${TABLE_NAME} --key '${keyjson}' --attribute-updates '${insertjson}'")
  log "${cmd}"
    echo ${cmd} | sh
}

FetchAuthKey() {
    AuthKey=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} | ${JQ_COMMAND}  '.Items[]|.AuthKey|.S' | grep -v "null")
    AuthKey=$(echo ${AuthKey} | sed s/\"//g)
    AuthKey=$(echo ${AuthKey} | sed s/\ //g)
    echo ${AuthKey}
}

# ------------------------------------------------------------------
#          Use private ip as primary hash key
#          Set Status of node
#          Usage SetMyStatus "INSTALL_STARTED"
#                SetMyStatus "INSTALL_COMPLETE" etc
# ------------------------------------------------------------------

SetMyStatus() {
    status=$1
    if [ -z "$status" ]; then
        echo "Invalid Status Update!"
        return
    fi
    keyjson_template='{"PrivateIpAddress": {
        "S": "myip"
        }}'
    myip=${MYPRIVATEIP}
    keyjson=$(echo -n ${keyjson_template} | sed "s/myip/${myip}/g")

    updatejson_template='{"Status": {
                "Value": {
                    "S": "mystatus"
                },
                "Action": "PUT"
            }
        }'

    updatejson=$(echo -n ${updatejson_template} | sed "s/mystatus/${status}/g")
    cmd=$(echo  "${AWS_CMD} dynamodb update-item --table-name ${TABLE_NAME} --key '${keyjson}' --attribute-updates '${updatejson}'")
    echo "${AWS_CMD} dynamodb update-item --table-name ${TABLE_NAME} --key '${keyjson}' --attribute-updates '${updatejson}'"
    echo ${cmd} | sh

}


# ------------------------------------------------------------------
#          Use Status column in DDB to orchestrate
#          Count number of hosts in specific state
#          When querying for nodes in WORKING state,
#          proceed if WORKING + FINISHED count >= EXPECTED_COUNT
#          This is necessary because secondary may move to FINISHED state before primary.
#          Usage: QueryStatusCount "INSTALL_COMPLETE"
#                 Get total hosts which have Status=INSTALL_COMPLETE
# ------------------------------------------------------------------

QueryStatusCount(){
    status=$1
    nodeType=$2
    if [ -z "$status" ]; then
        echo "StatusCountQuery invalid!"
        return
    fi
    count=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"${status}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --scan-filter '
             { "NodeType" : {
                "AttributeValueList": [
                    {
                        "S": '\"${nodeType}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} '| ${JQ_COMMAND}  '.Items[]|.PrivateIpAddress|.S' | wc -l)

    if [ "$status" == "WORKING" ]; then
        finished_count=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"FINISHED\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --scan-filter '
            { "NodeType" : {
                "AttributeValueList": [
                    {
                        "S": '\"${nodeType}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} '| ${JQ_COMMAND}  '.Items[]|.PrivateIpAddress|.S' | wc -l)
    fi
    
    re='^[0-9]+$'
    if ! [[ $count =~ $re ]] ; then
        count=0
    fi

    if ! [[ $finished_count =~ $re ]] ; then
        finished_count=0
    fi
    
    echo $((count + finished_count))
}

# ------------------------------------------------------------------
#          Get Local IPv4 Addresses from DDB
#          Usage: GetIPv4Addrs 
#                 Get list of IPv4 Adrresses
# ------------------------------------------------------------------

GetIPv4Addrs(){
    NodeType=$1
    IPv4=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "Status" : {
                "AttributeValueList": [
                    {
                        "S": '\"FINISHED\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' --scan-filter '
            { "NodeType" : {
                "AttributeValueList": [
                    {
                        "S": '\"${NodeType}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} ' | ${JQ_COMMAND}  '.Items[]|.PrivateIpAddress|.S')
    IPv4=$(echo ${IPv4} | sed s/\"//g)
    echo ${IPv4}
}

# ------------------------------------------------------------------
#          Get Node index from DDB
#          Usage: GetNodeIndex
#                 Get index of the current node
# ------------------------------------------------------------------
GetNodeIndex(){
    INDEX=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} | ${JQ_COMMAND}  '.Items[]|.NodeIndex|.S')
    INDEX=$(echo ${INDEX} | sed s/\"//g)
    echo ${INDEX}
}

GetAllNodeInfo(){
    nodeType=$1
    export increase=$2
    ALLNODE=$(${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME} --scan-filter '
            { "NodeType" : {
                "AttributeValueList": [
                    {
                        "S": '\"${nodeType}\"'
                    }
                ],
                "ComparisonOperator":"EQ"
                }} '| ${JQ_COMMAND}  '.Items[]| "\(.NodeIndex|.S) \(.PrivateIpAddress|.S)"'|sed s/\"//g|awk '{
                print "n" (($1+ENVIRON["increase"]) % 3) "-" $2}
                  ')
    echo ${ALLNODE}
}
# ------------------------------------------------------------------
#          Wait until specific number hosts reach specific state
#          To wait until 5 nodes reach "INSTALL_COMPLETE" status:
#          Usage: WaitForSpecificStatus "INSTALL_COMPLETE=5" etc.
# ------------------------------------------------------------------

WaitForSpecificStatus() {
	log "WaitForSpecificStatus START ($1) in cluster-watch-engine.sh"

    status_count_pair=$1
    nodeType=$2
    if [ -z "$status_count_pair" ]; then
        echo "Invalid Status=count Values!"
        return
    fi
    log "Received ${status_count_pair} in cluster-watch-engine.sh"
    status=$(echo $status_count_pair | /usr/bin/awk -F'=' '{print $1}')
    expected_count=$(echo $status_count_pair | /usr/bin/awk -F'=' '{print $2}')
    log "Checking for ${status} = ${expected_count} times"

    while true; do
      count=$(QueryStatusCount ${status} ${nodeType})
      log "${count}..."
      if [ "${count}" -lt "${expected_count}" ]; then
        log "${count}/${expected_count} in ${status} status...Waiting"
        sleep 10
      else
        log "${count} out of ${expected_count} in ${status} status!"
        log "WaitForSpecificStatus END ($1) in cluster-watch-engine.sh"
        return
      fi
    done

}

# ------------------------------------------------------------------
#          Print table
# ------------------------------------------------------------------

Print() {
    ${AWS_CMD} dynamodb scan --table-name ${TABLE_NAME}
}


if [ $CREATE -eq 1 ]; then
    CreateTable ${TABLE_NAME}
    InitMyTable
fi

if [ $GET_IPv4 ]; then
    GetIPv4Addrs ${GET_IPv4}
fi

if [ $NEW_STATUS ]; then
    SetMyStatus ${NEW_STATUS}
fi

if [ $NEW_ITEM_PAIR ]; then
    InsertMyKeyValueS ${NEW_ITEM_PAIR}
fi

if [ $CREATE_KEY -eq 1 ]; then
    auth_key=$( openssl rand -base64 756 | grep -o [[:alnum:]] | tr -d '\n' )
    InsertMyKeyValueS "AuthKey=${auth_key}"
fi

if [ $FETCH_KEY -eq 1 ]; then
    FetchAuthKey
fi

if [ $QUERY_STATUS ]; then
    QueryStatusCount $QUERY_STATUS
fi


if [ $WAIT_STATUS_COUNT_PAIR ]; then
    WaitForSpecificStatus $WAIT_STATUS_COUNT_PAIR $NODETYPE
fi


if [ $PRINT -eq 1 ]; then
    Print
fi

if [ $BLOCK_UNTIL_TABLE_LIVE -eq 1 ]; then
	WaitUntilTableLive
fi

if [ $DELETE_TABLE -eq 1 ]; then
	DeleteTable
fi

if [ $GET_INDEX -eq 1 ]; then
  GetNodeIndex
fi

if [ $GET_ALLNODE ];  then
  GetAllNodeInfo ${NODETYPE} ${GET_ALLNODE}
fi	

