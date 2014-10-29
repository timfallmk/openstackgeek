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

password=$SG_SERVICE_PASSWORD
managementip=$SG_SERVICE_CONTROLLER_IP

# Add the apt source entries
touch /etc/apt/sources.list.d/midokura.list
echo "deb http://$repousername:$repopassword@apt.midokura.com/midonet/v1.7/stable trusty main non-free
" >> /etc/apt/sources.list.d/midokura.list
echo "deb http://$repousername:$repopassword@apt.midokura.com/openstack/icehouse/stable trusty main" >> /etc/apt/sources.list.d/midokura.list

touch /etc/apt/sources.list.d/datastax.list
echo "deb http://debian.datastax.com/community stable main" >> /etc/apt/sources.list.d/datastax.list

# Add the package signing keys
curl -k http://debian.datastax.com/debian/repo_key | apt-key add -
curl -k "http://$repousername:$repopassword@apt.midokura.com/packages.midokura.key" | apt-key add -

# install packages
apt-get update
apt-get install -y openjdk-7-jre-headless
apt-get install -y neutron-server neutron-dhcp-agent neutron-metadata-agent
apt-get install -y python-midonetclient python-neutron-plugin-midonet
apt-get install -y tomcat7 zookeeper zookeeperd zkdump cassandra=2.0.10
apt-get install -y midonet-api midolman
apt-mark hold cassandra

# edit keystone conf file to use templates and mysql
if [ -f /etc/neutron/neutron.conf.orig ]; then
  echo "Original backup of neutron config files exist. Your current configs will be modified by this script."
  cp /etc/neutron/neutron.conf.orig /etc/neutron/neutron.conf
else
  cp /etc/neutron/neutron.conf /etc/neutron/neutron.conf.orig
fi

# Edit the neutron.conf
sed -i "s,connection = sqlite:////var/lib/neutron/neutron.sqlite,connection = mysql://neutron:$password@$managementip/neutron," /etc/neutron/neutron.conf

sed -i "s,%SERVICE_TENANT_NAME%,service," /etc/neutron/neutron.conf
sed -i "s,%SERVICE_USER%,neutron," /etc/neutron/neutron.conf
sed -i "s,%SERVICE_PASSWORD%,$SG_SERVICE_PASSWORD," /etc/neutron/neutron.conf

sed -i "s,# auth_strategy = keystone,auth_strategy = keystone," /etc/neutron/neutron.conf

sed -i "s,core_plugin = neutron.plugins.ml2.plugin.Ml2Plugin,core_plugin = midonet.neutron.plugin.MidonetPluginV2," /etc/neutron/neutron.conf

# Edit the dhcp_agent.ini
sed -i "s,# use_namespaces = True,use_namespaces = True," /etc/neutron/dhcp_agent.ini
sed -i "s,enable_isolated_metadata = False,enable_isolated_metadata = True," /etc/neutron/dhcp_agent.ini

# Add midonet.ini
mkdir /etc/neutron/plugins/midonet
touch /etc/neutron/plugins/midonet/midonet.ini
echo "
[DATABASE]
sql_connection = mysql://neutron:$password@$managementip/neutron
[MIDONET]
# MidoNet API URL
midonet_uri = http://$managementip:8080/midonet-api
# MidoNet administrative user in Keystone
username = midonet
password = $password
# MidoNet administrative user's tenant
project_id = admin
" >> /etc/neutron/plugins/midonet/midonet.ini

# Change the plugin used by neutron
sed -i "s,NEUTRON_PLUGIN_CONFIG=\"/etc/neutron/plugins/ml2/ml2_conf.ini\",NEUTRON_PLUGIN_CONFIG=\"/etc/neutron/plugins/midonet/midonet.ini\"," /etc/default/neutron-server

# Register the midonet user in keystone and add roles
keystone user-create --name midonet --pass $password --email admin@localhost
keystone user-role-add --user midonet --tenant admin --role admin

# Register neutron service and endpoint
function get_id () {
    echo `$@ | awk '/ id / { print $4 }'`
}
NEUTRONSERVICEID=$(get_id keystone service-create --name neutron --type network --description Networking)
keystone endpoint-create --service-id $NEUTRONSERVICEID --publicurl http://"$managementip":9696 --adminurl http://"$managementip":9696 --internalurl http://"$managementip":9696

# Set container preferences
touch /etc/tomcat7/Catalina/localhost/midonet-api.xml
echo "
<Context
     path=\"/midonet-api\"
     docBase=\"/usr/share/midonet-api\"
     antiResourceLocking=\"false\"
     privileged=\"true\"
/>
" >> /etc/tomcat7/Catalina/localhost/midonet-api.xml

# Stop zookeeper and Cassandra
service cassandra stop
service zookeeper stop

# Zookeeper configuration
echo "
server.1=localhost:2888:3888
" >> /etc/zookeeper/conf/zoo.conf
touch /etc/zookeeper/conf/myid
echo "1" >> /etc/zookeeper/conf/myid

# Cassandra configuration
sed -i "s,Test Cluster,midonet," /etc/cassandra/cassandra.yaml

# Clear the Cassandra data directory
rm -rf /var/lib/cassandra/data/

# Start Zookeeper and Cassandra
service cassandra start
service zookeeper start

# API configuration
sed -i "s,999888777666,$SG_SERVICE_TOKEN," /usr/share/midonet-api/WEB-INF/web.xml

# Set qemu port ACL's (this is kinda hacky, I want to find a better way of doing this substitution)
echo "
cgroup_device_acl = [
    \"/dev/null\", \"/dev/full\", \"/dev/zero\",
    \"/dev/random\", \"/dev/urandom\",
    \"/dev/ptmx\", \"/dev/kvm\", \"/dev/kqemu\",
    \"/dev/rtc\",\"/dev/hpet\", \"/dev/vfio/vfio\", \"/dev/net/tun\"
]
" >> /etc/libvirt/qemu.conf

service libvirt-bin restart

# Restart tomcat
service tomcat7 restart

# Start midolman
sleep 10
service midolman restart

# restart neutron services
service neutron-server restart
service neutron-metadata-agent restart
service neutron-dhcp-agent restart
service nova-compute restart

# Setup midonet-cli
touch ~/.midonetrc
echo "
[cli]
api_url = http://$managementip:8080/midonet-api
username = admin
password = $password
project_id = admin
" >> ~/.midonetrc

# Create the default tunnel zone and add members
MIDONETHOST=$(midonet-cli --eval list host | awk -F " " '{print $2}') # This should be looped for multi-node
TUNNELZONE=$(midonet-cli --eval tunnel-zone create name Default-GRE-Tunnel-Zone type gre)
midonet-cli --eval tunnel-zone $TUNNELZONE member add host $MIDONETHOST address 127.0.0.1 # This needs to be input in multi-node as well
MIDONETHOSTALIVE=$(midonet-cli --eval host $MIDONETHOST show alive)
if ($MIDONETHOSTALIVE) {echo "The host appears to be alive"}
else {echo "The host appears to be dead"}

echo;
echo "#################################################################################################

Your networking should now be configured.

#################################################################################################"
echo;

exit
