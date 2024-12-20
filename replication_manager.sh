#!/bin/bash
#
# replication_manager.sh
#
# Description:  Manages master-master replication between multiple PXC clusters.
#
# Authors:  Yves Trudeau, Percona
#
# License:  GNU General Public License (GPL)
#
# (c) 2017 Percona
#
# vim: set tabstop=4 shiftwidth=4 expandtab
#
# Requires the following table in the percona schema:
#
# CREATE TABLE `replication` (
#   `host` varchar(40) NOT NULL,
#   `weight` int(11) NOT NULL DEFAULT 0,
#   `localIndex` int(11) DEFAULT NULL,
#   `isReplica` enum('No','Yes','Proposed','Failed') DEFAULT 'No',
#   `lastUpdate` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
#   `lastHeartbeat` timestamp NOT NULL DEFAULT '1970-01-01 00:00:00',
#   `connectionName` varchar(64) NOT NULL,
#   `currentSource`   varchar(64),
#   PRIMARY KEY (`connectionName`,`host`),
#   KEY idx_host (`host`)
# ) ENGINE=InnoDB DEFAULT CHARSET=latin1
#
# CREATE TABLE `link` (
#   `clusterSlave` varchar(31) NOT NULL,
#   `clusterMaster` varchar(31) NOT NULL,
#   PRIMARY KEY (`clusterSlave`,`clusterMaster`)
# ) ENGINE=InnoDB DEFAULT CHARSET=latin1
#
# CREATE TABLE `cluster` (
#   `cluster` varchar(31) NOT NULL,
#   `masterCandidates` varchar(255) NOT NULL,
#   `replCreds` varchar(255) NOT NULL,
#   PRIMARY KEY (`cluster`)
# ) ENGINE=InnoDB DEFAULT CHARSET=latin1
#
# CREATE TABLE `weight` (
#   `cluster` varchar(31) NOT NULL,
#   `nodename` varchar(255) NOT NULL,
#   `weight` int NOT NULL DEFAULT 0,
#   PRIMARY KEY (`cluster`,`nodename`)
# ) ENGINE=InnoDB DEFAULT CHARSET=latin1
#
# The `link` table contains the topology you want to establish.  For example, if
# you have the following topology:
#     DC1 === DC2 === DC3
#              ||
#             DC4
# 
# with every link a master-master rel, the content will look like:
# 
# +---------------+-------------+
# | clusterSlave | clusterMaster |
# +---------------+-------------+
# | DC1           | DC2         |
# | DC2           | DC1         |
# | DC2           | DC3         |
# | DC2           | DC4         |
# | DC3           | DC2         |
# | DC4           | DC2         |
# +---------------+-------------+
# 
# The cluster table defines the remote cluster.  masterCandidates is a space 
# seperated list of remote masters, either fqdn or IPs, replCreds is the 
# fragment of the changes master command that provides authentication.  For 
# example, DC1 could be listed as:
#
# +---------+----------------------------------------------+-------------------------------------------------+
# | cluster | masterCandidates                             | replCreds                                       |
# +---------+----------------------------------------------+-------------------------------------------------+
# | DC1     | 172.29.110.132 172.29.110.133 172.29.110.134 | master_user='repl', master_password='repl_pass' |
# +---------+----------------------------------------------+-------------------------------------------------+
#
# If you need to add a custom port, just add master_port=3307 in the replCreds column.
#
# This script must be call every minutes by cron on every node that you 
# want to be a potential slave.  
# * * * * * /path/to/replication_manager.sh > /tmp/replication_manager.out
#
# The list of remote masters is defined by the variable: MASTERS_LIST  (see below)
#
# The mysql credentials needs to be in the .my.cnf file of the user under which
# the script run.  I needs SELECT, INSERT and UPDATE on percona.repliction 
# and SUPER on *.*
#
# Finally, the script requires GTID replication to be enabled.  If you are using 
# MariaDB GTID implementation, set the variable IS_MARIADB a few lines down
# to 1 otherwise 0.  For MariaDB, you'll need 10.1.4+ and the following variables:
# 
# wsrep_gtid_mode = ON
# wsrep_gtid_domain_id set to the the same value within a cluster and a distinct
# value between the clusters
# gtid_ignore_duplicates = ON
# server-id, same value within a cluster, disctinct across clusters
#
#exit
DEFAULTS_FILE=""
helptext(){
cat << EOF
Command line: Usage: $0 --defaults-file <location of the mysql default files>
    --defaults-file Location of the configuration file
    --send-email    Should we send an email if we see something not working? Default NO [boolean]


EOF
exit 0
}

# IF we should send Email or not default Not
SEND_EMAIL=0

#Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --defaults-file)
           DEFAULTS_FILE="$2"
           shift 2
           ;;
        --send-email)
            SEND_EMAIL=1
            shift
            ;;
        --help)
            helptext
            shift
            ;;                        
        *)
            echo "Unknown argument: $1"
			helptext
            exit 1
            ;;
    esac
done;

if [ ! "$DEFAULTS_FILE" == "" ]; then
    if [ ! -f $DEFAULTS_FILE ]; then
        echo "Default File path is wrong or file does not exists [$DEFAULTS_FILE]. Check correct file location or create file"
        exit 1
       else
        DEFAULTS_FILE=" --defaults-file=$DEFAULTS_FILE "
    fi
fi

DEBUG_LOG="/tmp/replication_manager.log"
if [ "${DEBUG_LOG}" -a -w "${DEBUG_LOG}" -a ! -L "${DEBUG_LOG}" ]; then
  exec 9>>"$DEBUG_LOG"
  exec 2>&9
  date >&9
  set -x
fi

if [ -f /tmp/replication_manager.off ]; then
    echo "/tmp/replication_manager.off exists, exiting now"
    exit 1
fi

#Global variables default values
FAILED_REPLICATION_TIMEOUT=179  # 3 times the cron interval minus 1s

# set it to the cluster size if you want to distribute the slave, 0 otherwise
DISTRIBUTE_REPLICA=3 

# IF we should send Email or not default Not
SEND_EMAIL=0


MYSQL="`which mysql` ${DEFAULTS_FILE} --connect_timeout=10 -B"

# retrieve the global status and set variables
get_status_and_variables() {
    eval `$MYSQL -N -e 'show global status;show global variables;' 2> /tmp/mysql_error | tr '\t' '=' | sed -e ':a' -e 'N' -e '$!ba' -e 's/,\n/, /g'     |grep -i -v -e 'wsrep_monitor_status' -e 'telemetry'| sed -e 's/^\([^=]*\)=\(.*\)$/\1='"'"'\2'"'"'/g'`

    if [ "$(grep -c ERROR /tmp/mysql_error)" -gt 0 ]; then
        cat /tmp/mysql_error
        exit 1
    fi
}

# This function returns 1 if the connection or channel exists
# and 0 otherwise
# argument: remoteCluster
slave_connchannel_exists() {
    local remoteCluster
    local cnt
    remoteCluster=$1
    
    if [ "$IS_MARIADB" -eq "1" ]; then
        cnt=$($MYSQL -N -e 'show all replica status\G' | grep -ci "${wsrep_cluster_name}-${remoteCluster}")
    else
        cnt=$($MYSQL -N -e 'show replica status\G' | grep -ci "${wsrep_cluster_name}-${remoteCluster}")
    fi
    echo $cnt;
}
# retrieve the slave status and set variables
get_slave_status() {
# argument is the remote cluster
    local remoteCluster
    local cnt
    remoteCluster=$1

    cnt=$(slave_connchannel_exists $remoteCluster)
    if [ "$IS_MARIADB" -eq "1" ]; then
        if [ "$cnt" -eq 1 ]; then
            eval `$MYSQL -e "show replica '${wsrep_cluster_name}-${remoteCluster}' status\G" 2> /tmp/mysql_error | grep -v Last | grep -v '\*\*\*\*' | sed -e ':a' -e 'N' -e '$!ba' -e 's/,\n/, /g' | sed -e 's/^\s*//g' -e 's/: /=/g' -e 's/\(.*\)=\(.*\)$/\1='"'"'\2'"'"'/g'`
        else
            unset Source_Host
        fi
    else
        if [ "$cnt" -eq 1 ]; then
            eval `$MYSQL -e "show replica status for channel '${wsrep_cluster_name}-${remoteCluster}'\G" 2> /tmp/mysql_error | grep -v Last | grep -v '\*\*\*\*' | sed -e ':a' -e 'N' -e '$!ba' -e 's/,\n/, /g' | sed -e 's/^\s*//g' -e 's/: /=/g' -e 's/\(.*\)=\(.*\)$/\1='"'"'\2'"'"'/g'`
        else
            unset Source_Host
        fi    
    fi
    
    if [ "$(grep -c ERROR /tmp/mysql_error)" -gt 0 ]; then
        cat /tmp/mysql_error
        exit 1
    fi        
        
}

send_email() {
    if [ $SEND_EMAIL > 0 ];then 
        Mailer=$(which mail)
        if [[ ${#EMAIL} -gt 0 && ${#Mailer} -gt 0 ]]; then
            echo "$1" | $Mailer -s "$2" $EMAIL
        fi
    fi
}
find_best_slave_candidate() {
    # argument is the remote cluster
    # we want the proposed if any, if not the lowest localIndex that has a valid lastHeartbeat
    $MYSQL -N -e "
    select r.host 
     from percona.replication r 
       inner join (select sum(if(isReplica = 'Yes',1,0)) as currentLinks, host 
                   from percona.replication rc group by host) as rc 
         on rc.host = r.host 
     where isReplica != 'Failed' 
       and connectionName = '${wsrep_cluster_name}-${1}'
       and unix_timestamp(lastHeartbeat) > unix_timestamp() - $FAILED_REPLICATION_TIMEOUT      
     order by weight desc, localIndex+currentLinks*${DISTRIBUTE_REPLICA} 
     limit 1;"
}

try_masters() {
    # argument is the remote cluster
    local masterOk=0
    local remoteCluster
    remoteCluster=$1
    
    REPLICATION_CREDENTIALS=$($MYSQL -N -e "select replCreds from percona.cluster where cluster = '${remoteCluster}';")
        
    for master in $($MYSQL -N -e "select masterCandidates from percona.cluster where cluster = '${remoteCluster}';"); do
        if [ "$IS_MARIADB" -eq "1" ]; then
            
            if [ "$(slave_connchannel_exists $remoteCluster)" -eq "1" ]; then
                $MYSQL -N -e "stop replica '${wsrep_cluster_name}-${remoteCluster}';"
            fi
            
            $MYSQL -N -e "
             CHANGE REPLICATION SOURCE TO '${wsrep_cluster_name}-${remoteCluster}' to SOURCE_HOST='$master', 
              ${REPLICATION_CREDENTIALS}, SOURCE_USE_GTID = slave_pos,
              IGNORE_DOMAIN_IDS = (${wsrep_gtid_domain_id});
            set global gtid_slave_pos='${gtid_binlog_pos}';
            start replica '${wsrep_cluster_name}-${remoteCluster}';"
        else
            if [ "$(slave_connchannel_exists $remoteCluster)" -eq "1" ]; then
                $MYSQL -N -e "stop replica for channel '${wsrep_cluster_name}-${remoteCluster}';"
            fi
            
            $MYSQL -N -e "
            CHANGE REPLICATION SOURCE TO SOURCE_HOST='${master}', ${REPLICATION_CREDENTIALS}, SOURCE_AUTO_POSITION = 1 for channel '${wsrep_cluster_name}-${remoteCluster}'; 
            start replica for channel '${wsrep_cluster_name}-${remoteCluster}';"
        fi
        sleep 10  # Give some time for replication to settle
        get_slave_status $remoteCluster
        stateOk=$(echo $Replica_IO_Running | grep -ci connect) # anything with connect in Replica_IO_Running is bad
        if [[ $Replica_IO_Running == "Yes" && $Replica_SQL_Running == "Yes" && $stateOk -eq 0 ]]; then
            masterOk=1
            break
        fi
    done
    echo $masterOk
}

# This function looks if this node is the best candidate and setup replicaition if it is.
setup_replication(){
    # argument is the remote cluster
    local myState
    local remoteCluster
    
    remoteCluster=$1
    
    # no slave are defined for the cluster
    CandidateSlave=$(find_best_slave_candidate $remoteCluster)
    
    if [ "$CandidateSlave" == "$wsrep_node_name" ]; then
        #we are the best candidate for that connection
        myState=$($MYSQL -N -e "select isReplica from percona.replication where connectionName = '${wsrep_cluster_name}-${remoteCluster}' and host = '$wsrep_node_name'")
        
        if [ "$myState" == "Proposed" ]; then
            # We are already at the proposed stated, we can setup replication
            
            masterOk=$(try_masters $remoteCluster)
            if [ "$masterOk" -eq 1 ]; then
                # all good, let's proclaim we are the slave
                $MYSQL -e "
                update percona.replication 
                 set isReplica='Yes', lastUpdate=now(), lastHeartbeat=now(),currentSource='$Source_Host' 
                 where connectionName =  '${wsrep_cluster_name}-${remoteCluster}' 
                 and host = '$wsrep_node_name'"
              
                send_email "Node $wsrep_node_name is the new replica for the connectionName '${wsrep_cluster_name}-${remoteCluster}'" "New replica"  
            else
                # this node failed to setup replication
                $MYSQL -e "
                update percona.replication 
                set isReplica='Failed', lastUpdate=now(), lastHeartbeat=now(),currentSource=''  
                where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                  and host = '$wsrep_node_name'"
                
                send_email "Node $wsrep_node_name failed to become the new replica for the connectionName '${wsrep_cluster_name}-${remoteCluster}'" "Failed replica"  
            fi
            
        elif [ "$myState" == "No" ]; then
            # update to Proposed, the use of the TRX and for update is to avoid a race condition.  The actual promotion to
            # slave will happen at the next call
            $MYSQL -e \
            "begin; 
             select count(*) into @dummy 
               from percona.replication 
               where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
               for update; 
             select host into @hostproposed 
               from percona.replication 
               where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                 and isReplica = 'Proposed' 
                 and unix_timestamp(lastHeartbeat) > unix_timestamp() - $FAILED_REPLICATION_TIMEOUT;
              update percona.replication set isReplica='Proposed', localIndex=$wsrep_local_index, lastUpdate=now(), lastHeartbeat=now(),currentSource=''  
                where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                  and host = '$wsrep_node_name' 
                  and host <> coalesce(@hostproposed,' ');
             commit;"    
        fi
    else
        # this node is not the best candidate for slave, this will reset status 'Failed' when there is no slave
        if [ "a$Source_Host" == "a" ]; then   # sanity check
            $MYSQL -e "
            update percona.replication 
             set isReplica='No', localIndex=$wsrep_local_index, lastHeartbeat=now(),currentSource=''  
             where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
               and host = '$wsrep_node_name'"    
        fi
    fi
}

# Stop, reset replication and update status 
# argument: status 
bail_out() {
local isReplicaVal
isReplicaVal=$1

    if [ "$IS_MARIADB" -eq "1" ]; then
        $MYSQL -e "
        stop replica '${wsrep_cluster_name}-${remoteCluster}'; 
        reset replica '${wsrep_cluster_name}-${remoteCluster}' all;" 
    else
        $MYSQL -e "
        stop replica for channel '${wsrep_cluster_name}-${remoteCluster}'; 
        reset replica all for channel '${wsrep_cluster_name}-${remoteCluster}';"
    fi

    $MYSQL -e "
    update percona.replication 
     set isReplica='${isReplicaVal}', localIndex=$wsrep_local_index, lastHeartbeat=now(),currentSource='$Source_Host'  
     where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
     and host = '$wsrep_node_name'" 
}

get_status_and_variables

# Is this a MariaDB server?
IS_MARIADB=$(echo "$version" | grep -ci mariadb)

if [[ $wsrep_cluster_status == 'Primary' && ( $wsrep_local_state -eq 4 \
    || $wsrep_local_state -eq 2 ) ]]; then
    # cluster is sane for this node

    for remoteCluster in $($MYSQL -N -e "select clusterMaster from percona.link where clusterSlave = '$wsrep_cluster_name';"); do
        # this list all the links we need to care about here
        
        myState=`$MYSQL -N -e "select isReplica from percona.replication where connectionName = '${wsrep_cluster_name}-${remoteCluster}' and host = '$wsrep_node_name';"`
        slaveDefined=`$MYSQL -N -e "select concat(host,'|', unix_timestamp() - unix_timestamp(lastHeartbeat)) from percona.replication where isReplica='Yes' and connectionName = '${wsrep_cluster_name}-${remoteCluster}' order by localIndex limit 1"`

        get_slave_status $remoteCluster
        
        if [ "a$Source_Host" == "a" ]; then 
            # This node is not currently a slave
            
            if [ "a$myState" == "a" ]; then
                # no row in percona.replication for that node, must be added
                  #identify if host has weight assign and if not default it to 0
                  nodeWeight=`$MYSQL -N -e "select  weight from percona.weight where cluster = '${wsrep_cluster_name}' and nodename = '$wsrep_node_name';"`
                  if [ -z  $nodeWeight ]; then nodeWeight=0;fi

                
                $MYSQL -e "
                insert into percona.replication 
                 (host,weight,connectionName,localIndex,isReplica,lastUpdate,lastHeartbeat) 
                 Values ('$wsrep_node_name','${nodeWeight}','${wsrep_cluster_name}-${remoteCluster}',$wsrep_local_index,'No',now(),now())" 
                myState=No
            elif [ "$myState" == "Failed" ]; then
                # Clear the failed state after twice the normal timeout
                $MYSQL -e "
                update percona.replication 
                 set isReplica='No', localIndex=$wsrep_local_index, lastUpdate=now(), lastHeartbeat=now() 
                 where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                   and host = '$wsrep_node_name' 
                   and unix_timestamp(lastUpdate) < unix_timestamp() - 2*$FAILED_REPLICATION_TIMEOUT"
            fi

            if [ "a$slaveDefined" == "a" ]; then
                # no slave are defined in the cluster
                setup_replication $remoteCluster 
            else
                # There is a slave defined
                lastHeartbeat=$(echo $slaveDefined | cut -d'|' -f2)
                slaveHost=$(echo $slaveDefined | cut -d'|' -f1)
                
                if [ "$lastHeartbeat" -gt "$FAILED_REPLICATION_TIMEOUT" ]; then
                    # the current slave is not reporting, 
                    $MYSQL -e "
                    update percona.replication 
                     set isReplica='No' 
                     where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                       and host = '$slaveHost'"
                    
                    send_email "Node $slaveHost is the slave but failed to report in time for the connectionName  '${wsrep_cluster_name}-${remoteCluster}'" "Slave node timeout"
                    
                    setup_replication $remoteCluster
                else
                    # Slave is reporting, this is the sane path for a node that isn't the slave
                    $MYSQL -e "
                    update percona.replication 
                     set isReplica='No', localIndex=$wsrep_local_index, lastHeartbeat=now() 
                     where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                       and host = '$wsrep_node_name'"                
                fi
            fi
        else
            # This node is a slave
            
            if [ "a$myState" == "a" ]; then
                # no row in percona.replication for that node
                
                if [ "a$slaveDefined" == "a" ]; then
                    # no row in percona.replication, likely uninitialized and we are the slave
                    
                    #identify if host has weight assign and if not default it to 0
                    nodeWeight=`$MYSQL -N -e "select  weight from percona.weight where cluster = '${wsrep_cluster_name}' and nodename = '$wsrep_node_name';"`
                    if [ -z  $nodeWeight ]; then nodeWeight=0;fi
                    
                    $MYSQL -e "
                    insert into percona.replication (host,weight,connectionName,localIndex,isReplica,lastUpdate,lastHeartbeat) 
                    Values ('$wsrep_node_name','$nodeWeight','${wsrep_cluster_name}-${remoteCluster}',$wsrep_local_index,'Yes',now(),now())" 
                else
                    # That could be problematic, another slave exists let's bail-out
                    bail_out No
                fi
            elif [ "$myState" == "Yes" ]; then
                # myState is defined
                if [[ $Replica_IO_Running == "Yes" && $Replica_SQL_Running == "Yes" ]]; then
                    #replication is going ok, the sane path when the node is a slave
                    $MYSQL -e "
                    update percona.replication 
                     set isReplica='Yes', localIndex=$wsrep_local_index, lastHeartbeat=now(),currentSource='$Source_Host' 
                     where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                     and host = '$wsrep_node_name'"    
            
                else
                    #replication is broken
                    if [ "$Replica_SQL_Running" == "No" ]; then
                        # That's bad, replication failed, let's bailout
                        bail_out Failed
                        
                        send_email "Node $wsrep_node_name failed as a replica for the connectionName '${wsrep_cluster_name}-${remoteCluster}', SQL thread not running" "Failed replica"  
                        
                    elif [[ $Replica_IO_Running != "Yes" && $Replica_SQL_Running == "Yes" ]]; then
                        # Looks like we cannot reach the master, let's try to reconnect
                        
                        masterOk=$(try_masters $remoteCluster)
                        if [ "$masterOk" -eq 1 ]; then
                            # we succeeded reconnecting
                            $MYSQL -e "
                            update percona.replication 
                             set isReplica='Yes', localIndex=$wsrep_local_index, lastHeartbeat=now(),currentSource='$Source_Host' 
                             where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                               and host = '$wsrep_node_name'"         
                        else
                            # We failed, bailing-out
                            bail_out Failed
                            send_email "Node $wsrep_node_name failed as a replica for the cluster $wsrep_cluster_name, IO thread not running" "Failed replica"
                        fi
                    fi
                fi
                
                # Sanity check, is there more than one slave reporting for the connection?
                slaveCount=$($MYSQL -BN -e "select count(*) from percona.replication where isReplica = 'Yes' and connectionName = '${wsrep_cluster_name}-${remoteCluster}' and unix_timestamp(lastHeartbeat) > unix_timestamp() - $FAILED_REPLICATION_TIMEOUT")
                if [ "$slaveCount" -gt 1 ]; then
                    # that's bad, more than one replica for the cluster... bailout
                    bail_out No
                    
                    send_email "Two nodes were replicas for the cluster $wsrep_cluster_name, stopping replica on node $wsrep_node_name" "Two replicas"
                    
                fi
                
            elif [ "$myState" == "No" ]; then
                # We are not defined as a replica in the cluster but we are... bailout
                bail_out No
            elif [ "$myState" == "Failed" ]; then
                # We have failed and we are a replica, this is abnormal, fix state to 'No' and bailout
                bail_out No
            elif [ "$myState" == "Proposed" ]; then
                # Sanity cleanup, if the node is a replica is still at Proposed, need to be updated
                $MYSQL -e "
                update percona.replication 
                set isReplica='Yes', localIndex=$wsrep_local_index, lastHeartbeat=now() 
                where connectionName = '${wsrep_cluster_name}-${remoteCluster}' 
                  and host = '$wsrep_node_name'"  
            fi
        fi
    done
else
    # cluster node is not sane for this node

    if [ "a$Source_Host" != "a" ]; then 
        # This node is currently a replica but not in the primary group, bailing out
        bail_out No
        send_email "Node $wsrep_node_name is not longer part of the cluster $wsrep_cluster_name, stopping replication" "Failed replica"
    fi

    # Nothing else to do
fi
