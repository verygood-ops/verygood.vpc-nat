#!/bin/bash
set -e -x

function log { logger -t "vpc" -- $1; }

function die {
	[ -n "$1" ] && log "$1"
	log "Configuration of HA NAT failed!"
	exit 1
}

# Sanitize PATH
PATH="/usr/sbin:/sbin:/usr/bin:/bin"

log "Beginning Port Address Translator (PAT) configuration..."
log "Determining the MAC address on eth0..."

ETH0_MAC=$(cat /sys/class/net/eth0/address) ||
die "Unable to determine MAC address on eth0."
log "Found MAC ${ETH0_MAC} for eth0."

VPC_CIDR_URI="http://169.254.169.254/latest/meta-data/network/interfaces/macs/${ETH0_MAC}/vpc-ipv4-cidr-block"
VPC_ID_URI="http://169.254.169.254/latest/meta-data/network/interfaces/macs/${ETH0_MAC}/vpc-id"
log "Metadata location for vpc ipv4 range: ${VPC_CIDR_URI}"

VPC_CIDR_RANGE=$(curl --retry 3 --silent --fail ${VPC_CIDR_URI})
VPC_ID=$(curl --retry 3 --silent --fail ${VPC_ID_URI})

if [ $? -ne 0 ]; then
    log "Unable to retrive VPC CIDR range from meta-data, using 0.0.0.0/0
    instead. PAT may be insecure."
    VPC_CIDR_RANGE="0.0.0.0/0"
else
    log "Retrieved VPC CIDR range ${VPC_CIDR_RANGE} from meta-data."
fi

sysctl -q -w net.ipv4.ip_forward=1 net.ipv4.conf.eth0.send_redirects=0 && (
    iptables -t nat -C POSTROUTING -o eth0 -s ${VPC_CIDR_RANGE} -j MASQUERADE 2> /dev/null ||
    iptables -t nat -A POSTROUTING -o eth0 -s ${VPC_CIDR_RANGE} -j MASQUERADE
) || die

export AWS_DEFAULT_OUTPUT="text"

sysctl net.ipv4.ip_forward net.ipv4.conf.eth0.send_redirects | log
iptables -n -t nat -L POSTROUTING | log

easy_install --upgrade awscli && log "AWS CLI Upgraded Successfully. Beginning HA NAT configuration..."

# Set Instance Identity URI
II_URI="http://169.254.169.254/latest/dynamic/instance-identity/document"

# Set region of NAT instance
REGION=`curl --retry 3 --retry-delay 0 --silent --fail $II_URI | grep region | awk -F\" '{print $4}'`

# Set AWS CLI default Region
export AWS_DEFAULT_REGION=$REGION

# Set AZ of NAT instance
AVAILABILITY_ZONE=`curl --retry 3 --retry-delay 0 --silent --fail $II_URI | grep availabilityZone | awk -F\" '{print $4}'`

# Set Instance ID from metadata
INSTANCE_ID=`curl --retry 3 --retry-delay 0 --silent --fail $II_URI | grep instanceId | awk -F\" '{print $4}'`

# The ENI is used for routing so we must attach it to the instance, this completes the route
ENI_ID=`aws ec2 describe-network-interfaces --query "NetworkInterfaces[*].NetworkInterfaceId" --filters "Name=availability-zone,Values=$AVAILABILITY_ZONE" "Name=tag-value,Values=nat" "Name=tag-key,Values=role"`
aws ec2 attach-network-interface --network-interface-id=$ENI_ID --instance-id=$INSTANCE_ID --device-index=1 || die "Unable to attach ENI"

# The EIP is what we publicly expose and is an output from this template. The EIP should not change if another instance takes over.

# check if already associated
if `aws ec2 describe-addresses | grep -q $ENI_ID`; then
    log "Address already associated"
else
    EIP=`aws ec2 describe-addresses | grep -v eipassoc | head -n1 | awk -F" " '{print $2}'`
    aws ec2 associate-address --allocation-id=$EIP --network-interface-id=$ENI_ID
    log "Associated address"
fi

# find attached network interfaces
NETWORK_INTERFACES=`aws ec2 describe-network-interfaces --filters Name=attachment.instance-id,Values=$INSTANCE_ID | grep eni | grep NETWORKINTERFACES | grep -oP eni-[a-zA-Z0-9]+`

# disable src/dest check
for ENI in $NETWORK_INTERFACES
do
    aws ec2 modify-network-interface-attribute --network-interface-id=$ENI --no-source-dest-check &&
        log "Source Destination check disabled for $INSTANCE_ID - $ENI."
done

# change route tables
ROUTE_TABLE=`aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-value,Values=$AVAILABILITY_ZONE" "Name=tag-key,Values=Region" | grep ROUTETABLES | grep -oP rtb-[a-zA-Z0-9]+`

# replace route
aws ec2 replace-route --route-table-id=$ROUTE_TABLE --destination-cidr-block=0.0.0.0/0 --network-interface-id `echo $NETWORK_INTERFACES | sed "s/$ENI_ID//"`

cat /etc/network/interfaces.d/eth0.cfg | sed 's/eth0/eth1/' > /etc/network/interfaces.d/eth1.cfg
ifup eth1

echo "finished"
