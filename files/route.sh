#!/bin/bash
set -e -x

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

while : ; do
        if [ $(ifconfig eth1 | grep -o eth1) = "eth1" ]; then
                echo "eth1 is up and running!" 
                ifup eth1
								sleep 10
                route add default eth1
                route delete default eth0
                exit $?;
        else
                echo "waiting for eth1" 
                sleep 10
        fi
done
