#!/bin/bash

# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
   echo "You need to be 'root' dude." 1>&2
   exit 1
fi

# source the setup file
. ./setuprc

clear 

echo;
echo "##############################################################################################"
echo;
echo "This will setup OpenStack Neutron to use MidoNet SDN."
echo "You must have access to MidoNet repositories."
echo;
echo "For more information on MidoNet, please visit http://www.midokura.com"
echo;
echo "##############################################################################################"
echo;

read -p "Please enter your midokura repo username: " repousername
echo;
read -p "Please enter your midokura repo password: " repopassword

# Add the apt source entries
touch /etc/apt/sources.list.d/midokura.list
echo "deb http://$repousername:$repopassword@apt.midokura.com/midonet/v1.7/stable trusty main non-free\n" >> /etc/apt/sources.list.d/midokura.list
echo "deb http://$repousername:$repopassword@apt.midokura.com/openstack/icehouse/stable trusty main\n" >> /etc/apt/sources.list.d/midokura.list

touch /etc/apt/sources.list.d/datastax.list
echo "deb http://debian.datastax.com/community stable main" >> /etc/apt/sources.list.d/datastax.list

# Add the package signing keys
curl -k http://debian.datastax.com/debian/repo_key | apt-key add -
curl -k "http://$repousername:$repopassword@apt.midokura.com/packages.midokura.key" | apt-key add -

# install packages
apt-get install -y neutron-server neutron-dhcp-agent neutron-metadata-agent
apt-get install -y python-midonetclient python-neutron-plugin-midonet
apt-get install -y midonet-api tomcat7 zookeeper zookeeperd zkdump cassandra=2.0.10

# edit keystone conf file to use templates and mysql
if [ -f /etc/neutron/neutron.conf.orig ]; then
  echo "Original backup of neutron config files exist. Your current configs will be modified by this script."
  cp /etc/neutron/neutron.conf.orig /etc/neutron/neutron.conf
else
  cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.orig
fi

echo "
rpc_backend = neutron.openstack.common.rpc.impl_kombu
rabbit_host = localhost
rabbit_port = 5672
rabbit_userid = guest
rabbit_password = guest

[database]
connection = mysql://neutron:$password@$managementip/neutron

[keystone_authtoken]
auth_uri = http://$managementip:5000
auth_host = $managementip
auth_port = 35357
auth_protocol = http
admin_tenant_name = service
admin_user = neutron
admin_password = $password
" >> /etc/neutron/neutron.conf

# Set container preferences
touch /usr/share/tomcat7/Catalina/localhost/midonet-api.xml
echo "
<Context
     path="/midonet-api"
     docBase="/usr/share/midonet-api"
     antiResourceLocking="false"
     privileged="true"
/>
" >> /usr/share/tomcat7/Catalina/localhost/midonet-api.xml

# Start zookeeper and Cassandra
service cassandra stop
service zookeeper stop

# Clear the Cassandra data directory
rm -rf /var/lib/cassandra/data/

# restart neutron services
service neutron-server restart
service neutron-metadata-agent restart
service neutron-dhcp-agent restart
service  restart

echo;
echo "#################################################################################################

Run ./openstack_loop.sh to setup the cinder-volumes loopback device.

#################################################################################################"
echo;

exit
