#!/bin/bash
# A Poor man's sentinel for keeping two redis instances in check.
# This ensures there is always a Master to talk to. If Redis1 goes down, Redis2 will be promoted
# As well, Redis2 will be demoted in the event Redis1 is back up.
# When Redis1 comes back online, we determine which redis is being used the most, to determine an rdb sync
# for minimal to no data loss
# 
# Writen by: Joe Engel
# Additional Contributors: Mark Lessel - https://github.com/magglass1
#
#!/bin/bash

# IP/Port For Master
MASTER_IP=''
MASTER_PORT=''

# First ensure that Redis is running on Redis2 or is intended to be stopped
if ! /sbin/pidof redis-server > /dev/null
then
        if [ -f /var/run/redis.pid ]
	then
		rm /var/run/redis.pid
		echo "[$(date) Starting Redis"
		/sbin/service redis-server start
	else
		echo "[$(date)] Redis2 was stopped, no pid file found, taking no action."
		exit
	fi
fi

# Check to see if Redis1 is responding
/usr/local/bin/redis-cli -h $MASTER_IP ping > /dev/null 2>&1

# Get the response code back
res=$?

# Get current master/slave status of Redis2
getInfo=`/usr/local/bin/redis-cli INFO | grep -oP 'role:\w+'`

# If Redis1 is not responding
if [ $res != 0 ]
then
	# Avoid flapping
	if [ -f /var/lib/redis/hasfailed ]
	then
		# If Redis2 is already a master, do nothing
		if [ "$getInfo" == "role:master" ]
		then
			echo "[$(date)] Redis1 not responding and Redis2 is already a master!"
			exit
		# If Redis2 is currently a slave, promote it to master
		elif [ "$getInfo" == "role:slave" ]
		then
			echo "[$(date)] Redis1 not responding and Redis2 becoming a master now"
			/usr/local/bin/redis-cli SLAVEOF no one > /dev/null && echo "[$(date)] Redis2 is now a master" || ( echo "[$(date)] Failed to set Redis2 to master"; exit )
			REDIS_INFO=$(/usr/local/bin/redis-cli info | /usr/bin/dos2unix)
			if [ $? == 0 ]
			then
				echo "$REDIS_INFO" | fgrep total_commands_processed | cut -d: -f2 > /var/lib/redis/redis2_cmds
			fi
		else
			echo "[$(date)] Failed to check state of Redis2"
			exit
		fi
	else
		touch /var/lib/redis/hasfailed
		echo "[$(date)] Redis1 failure detected, will sanity check again"
		exit
	fi

# If Redis1 is responding
else
	echo "[$(date)] Redis1 is online"
	rm -f /var/lib/redis/hasfailed
	# If Redis2 is currently a master after Redis1 is back online
	if [ "$getInfo" == "role:master" ]
	then
		REDIS_INFO=$(/usr/local/bin/redis-cli -h $MASTER_IP info | /usr/bin/dos2unix)
		if [ $? == 0 ]
		then
			REDIS1_CMDS=$(echo "$REDIS_INFO" | fgrep total_commands_processed | cut -d: -f2)
			REDIS1_PREV_CMDS=$(cat /var/lib/redis/redis1_cmds || echo 0)
			if [ -z $REDIS1_PREV_CMDS ]
			then
				REDIS1_PREV_CMDS=0
			fi
			REDIS_INFO=$(/usr/local/bin/redis-cli info | /usr/bin/dos2unix)
			if [ $? == 0 ]
			then
				REDIS2_CMDS=$(echo "$REDIS_INFO" | fgrep total_commands_processed | cut -d: -f2)
				REDIS2_PREV_CMDS=$(cat /var/lib/redis/redis2_cmds || echo 0)
				if [ -z $REDIS2_PREV_CMDS ]
				then
					REDIS2_PREV_CMDS=0
				fi
				REDIS1_DIFF=$(( $REDIS1_CMDS - $REDIS1_PREV_CMDS ))
				REDIS2_DIFF=$(( $REDIS2_CMDS - $REDIS2_PREV_CMDS ))
				echo "[$(date)] Redis1 diff: $REDIS1_DIFF"
				echo "[$(date)] Redis2 diff: $REDIS2_DIFF"
				if [ $REDIS1_DIFF -lt $REDIS2_DIFF ]
				then
					# Take an RDB snap and scp it to Redis1
					/usr/local/bin/redis-cli SAVE > /dev/null && echo "[$(date)] Taking on demand snapshot to send to Redis1"
					/usr/bin/sudo -u redis /usr/bin/ssh redis@$MASTER_IP 'sudo /etc/init.d/redis-server stop' > /dev/null || ( echo "[$(date) Failed to stop redis"; exit )
					/usr/bin/sudo -u redis /usr/bin/scp /var/lib/redis/dump.rdb redis@$MASTER_IP:/var/lib/redis/ > /dev/null && echo "[$(date)] Successfully synced RDB snapshot" || ( echo "[$(date) Failed to sync rdb snapshot"; exit )
					# SSH execute to stop and restart Redis to take advantage of the new rdb
					/usr/bin/sudo -u redis /usr/bin/ssh redis@$MASTER_IP 'sudo /etc/init.d/redis-server start' > /dev/null || ( echo "[$(date) Failed to start redis"; exit )
				fi
			fi
		fi
		# Now set Redis2 to a slaveof Redis1
		echo "[$(date)] Redis1 is supposed to be master, setting Redis2 as a slave of Redis1"
		/usr/local/bin/redis-cli SLAVEOF $MASTER_IP $MASTER_PORT > /dev/null && echo "[$(date)] Redis2 is now a slave" || ( echo "[$(date)] Failed to set Redis2 to slave"; exit )
	# Else, if Redis2 is already is a slave, do nothing
	elif [ "$getInfo" == "role:slave" ]
	then
		echo "[$(date)] Redis1 is master, Redis2 is already slave"
	else
		echo "[$(date) Failed to check state of Redis2"
	fi
	REDIS_INFO=$(/usr/local/bin/redis-cli -h $MASTER_IP info | /usr/bin/dos2unix)
	if [ $? == 0 ]
	then
		echo "$REDIS_INFO" | fgrep total_commands_processed | cut -d: -f2 > /var/lib/redis/redis1_cmds
	fi
fi

