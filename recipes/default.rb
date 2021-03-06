#
# Cookbook Name:: rundeck
# Recipe:: default
#
# Author:: Panagiotis Papadomitsos (<pj@ezgr.net>)
#
# Copyright 2013, Panagiotis Papadomitsos
#
# Licensed under the Apache License, Version 2.0 (the 'License');
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an 'AS IS' BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

include_recipe 'java'
include_recipe 'logrotate'

case node['platform_family']

when 'debian'

  remote_file "#{Chef::Config['file_cache_path']}/rundeck-#{node['rundeck']['deb_version']}.deb" do
    owner 'root'
    group 'root'
    mode 00644
    source node['rundeck']['deb_url']
    checksum node['rundeck']['deb_checksum']
    action :create
  end

  dpkg_package "#{Chef::Config['file_cache_path']}/rundeck-#{node['rundeck']['deb_version']}.deb" do
    action :install
  end

when 'rhel'

  remote_file "#{Chef::Config['file_cache_path']}/rundeck-config-#{node['rundeck']['rpm_version']}.noarch.rpm" do
    owner 'root'
    group 'root'
    mode 00644
    source node['rundeck']['rpm_cfg_url']
    checksum node['rundeck']['rpm_cfg_checksum']
    action :create
  end

  remote_file "#{Chef::Config['file_cache_path']}/rundeck-#{node['rundeck']['rpm_version']}.noarch.rpm" do
    owner 'root'
    group 'root'
    mode 00644
    source node['rundeck']['rpm_url']
    checksum node['rundeck']['rpm_checksum']
    action :create
  end

  execute "install-rundeck-#{node['rundeck']['rpm_version']}" do
    command "yum -y localinstall #{Chef::Config['file_cache_path']}/rundeck-#{node['rundeck']['rpm_version']}.noarch.rpm #{Chef::Config['file_cache_path']}/rundeck-config-#{node['rundeck']['rpm_version']}.noarch.rpm"
    action :run
    not_if "rpm -q rundeck | grep #{node['rundeck']['rpm_version']}"
  end

end

directory node['rundeck']['projects_dir'] do
  owner "rundeck"
  group "rundeck"
  mode 00755
  recursive true
  action :create
end

# Erase the default realm.properties after package install, we manage that
file '/etc/rundeck/realm.properties' do
  action :delete
end

if Chef::Config[:solo]
  secretsobj = data_bag_item(node['rundeck']['secrets']['data_bag'], node['rundeck']['secrets']['data_bag_id']) rescue {
    'admin_password'    => node['rundeck']['admin']['password'],
    'ssh_user_priv_key' => node['rundeck']['ssh']['user_priv_key']
  }
elsif node['rundeck']['secrets']['encrypted_data_bag']
  secretsobj = Chef::EncryptedDataBagItem.load(node['rundeck']['secrets']['data_bag'], node['rundeck']['secrets']['data_bag_id'])
else
  secretsobj = data_bag_item(node['rundeck']['secrets']['data_bag'], node['rundeck']['secrets']['data_bag_id'])
end

if Chef::Config[:solo]
  recipients = 'root'
else
  recipients = search(node['rundeck']['mail']['recipients_data_bag'], node['rundeck']['mail']['recipients_query']).
  map {|u| eval("u#{node['rundeck']['mail']['recipients_field']}") }.
  join(',') rescue []
end

directory '/etc/rundeck' do
	action :create
	not_if do ::File.directory?('/etc/rundeck') end
end

# Configuration properties
template '/etc/rundeck/framework.properties' do
  source 'framework.properties.erb'
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  variables({
    :admin_user => node['rundeck']['admin']['username'],
    :admin_pass => secretsobj['admin_password'],
    :recipients => recipients
  })
  notifies :restart, 'service[rundeckd]'
end

template '/etc/rundeck/project.properties' do
  source 'project.properties.erb'
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  variables({ :recipients => recipients })
  notifies :restart, 'service[rundeckd]'
end

template '/etc/rundeck/rundeck-config.properties' do
  source 'rundeck-config.properties.erb'
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  notifies :restart, 'service[rundeckd]'
end

# Rundeck profile file
template '/etc/rundeck/profile' do
  source 'rundeck.profile.erb'
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  action :create
  notifies :restart, 'service[rundeckd]'
end

## don't need to override these files
# Stub files from the cookbook, override with chef-rewind
#%w{ log4j.properties jaas-loginmodule.conf apitoken.aclpolicy admin.aclpolicy }.each do |cf|
#  cookbook_file "/etc/rundeck/#{cf}" do
#    source cf
#    owner 'rundeck'
#    group 'rundeck'
#    mode 00644
#    action :create
#  end
#end

template "/etc/rundeck/jaas-activedirectory.conf" do
  source "jaas-activedirectory.conf.erb"
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  action :create
  variables(
    :ldap => node['rundeck']['ldap'],
    :configdir => "/etc/rundeck"
  )
end

bash "web.xml" do
  code "sed -i 's|<role-name>.*</role-name>|<role-name>#{node['rundeck']['required_role']}</role-name>|'" +
       " /var/lib/rundeck/exp/webapp/WEB-INF/web.xml"
end

cookbook_file "/etc/rundeck/realm.properties" do
  source 'realm.properties'
  owner 'rundeck'
  group 'rundeck'
  mode 00644
  action :create_if_missing
end

rundeck_user node['rundeck']['admin']['username'] do
  password secretsobj['admin_password']
  encryption 'md5'
  roles [ node['rundeck']['required_role'], 'user', 'admin', 'architect', 'deploy', 'build' ]
  action :create
end

node['rundeck']['admins'].each do |user|
  pass = data_bag_item('users', user)
  rundeck_user user do
    password pass['auth_basic']
    encryption 'httppass'
    roles [ node['rundeck']['required_role'], 'user', 'admin', 'architect', 'deploy', 'build' ]
    action :create
  end
end

# Log rotation
logrotate_app 'rundeck' do
  path '/var/log/rundeck/*.log'
  enable true
  frequency 'daily'
  rotate 7
  cookbook 'logrotate'
  create '0644 rundeck adm'
  options [ 'missingok', 'delaycompress', 'notifempty', 'compress', 'sharedscripts', 'copytruncate' ]
end

# SSH private key. Stored in the data bag item as ssh_user_priv_key
unless secretsobj['ssh_user_priv_key'].nil? || secretsobj['ssh_user_priv_key'].empty?

  directory '/var/lib/rundeck/.ssh' do
    owner 'rundeck'
    group 'rundeck'
    mode 00750
    action :create
  end

  file '/var/lib/rundeck/.ssh/id_rsa' do
    action :create
    owner 'rundeck'
    group 'rundeck'
    mode 00600
    content secretsobj['ssh_user_priv_key']
  end

end

service 'rundeckd' do
  provider(Chef::Provider::Service::Upstart) if platform?('ubuntu') && node['platform_version'].to_f >= 12.04
  supports :status => true, :restart => true
  action :enable
end
