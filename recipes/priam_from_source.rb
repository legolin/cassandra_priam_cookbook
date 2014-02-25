#
# Cookbook Name:: cassandra-priam
# Recipe:: priam
#
# Copyright 2013 Medidata Solutions Worldwide
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

# Sudo entry to manage cassandra startup/shutdown via Priam
template "/etc/sudoers.d/tomcat" do
  source "tomcatsudo.erb"
  mode    0440
end

# Install build dendencies
package 'gradle'

# Download Priam source code
priam_source_cache_path = "#{Chef::Config[:file_cache_path]}/priam-#{node[:cassandra][:priam][:source][:git_revision]}"
git priam_source_cache_path do
  repository node[:cassandra][:priam][:source][:git_repository]
  reference node[:cassandra][:priam][:source][:git_revision]
  action :sync
  notifies :run, "bash[priam_src_apply_patch]"
  not_if  { File.exists? priam_source_cache_path }
end


# Get Priam version
#
ruby_block "get-priam-version" do
  block do
    version = File.read("#{priam_source_cache_path}/gradle.properties").scan(/version=([\w\d\.\-]+)/)[0][0]
    node.normal[:cassandra][:priam][:source][:version] = version
  end
  action :create
end

# Apply IAM patch if requested.
if node[:cassandra][:priam][:aws_credentials] == 'IAM'
  # Save the patch to the file
  cookbook_file "enableIAM.patch" do
    path "#{priam_source_cache_path}/enableIAM.patch"
    action :create_if_missing
  end

  # Apply the patch
  bash "priam_src_apply_patch" do
    cwd priam_source_cache_path
    code "git checkout . && git apply enableIAM.patch"
  end
end

# Build Priam
bash "priam_build" do
  cwd priam_source_cache_path
  code lazy { "./gradlew clean && ./gradlew build" }
  notifies :restart, "service[cassandra]", :delayed
  not_if "test -f #{priam_source_cache_path}/priam/build/libs/priam-#{node[:cassandra][:priam][:source][:version]}.jar"
end

# Install Priam
bash "install_priam" do
  code lazy { <<-EOL
  cp #{priam_source_cache_path}/priam-cass-extensions/build/libs/priam-cass-extensions-#{node[:cassandra][:priam][:source][:version]}.jar "#{node[:cassandra][:priam_cass_home]}/lib/priam-cass-extensions-#{node[:cassandra][:priam][:source][:version]}.jar"
    EOL
  }
end

# Give priam running as node[:tomcat][:user] access to write the Cassandra config
file "#{node[:cassandra][:priam_cass_home]}/conf/cassandra.yaml" do
  owner     "#{node[:tomcat][:user]}"
  group     "#{node[:tomcat][:group]}"
  mode      "0755"
  action    :touch
end

# Backup the original cassandra.in.sh script
#
bash 'backup-cassandra-init-script' do
  cwd node[:cassandra][:priam_cass_home]
  code 'cp bin/cassandra.in.sh bin/cassandra.in.sh.original'
  not_if { File.exist?("#{node[:cassandra][:priam_cass_home]}/bin/cassandra.in.sh.original") }
end

# Create a cassandra.in.sh script that adds the Priam agent
#
bash 'create-cassandra-init-script' do
  cwd node[:cassandra][:priam_cass_home]
  code lazy { <<-EOL
    cp bin/cassandra.in.sh.original bin/cassandra.in.sh
    echo "\n\nexport JVM_OPTS=\"-javaagent:\\$CASSANDRA_HOME/lib/priam-cass-extensions-#{node[:cassandra][:priam][:source][:version]}.jar\"" >> bin/cassandra.in.sh
    EOL
  }
end

# Give priam running as node[:tomcat][:user] access to the log file it wants to write to
file "/var/log/tomcat7/priam.log" do
  owner     "#{node[:tomcat][:user]}"
  group     "#{node[:tomcat][:group]}"
  mode      "0755"
  action    :touch
end

# Priam's War file goes into tomcat's special directory - this event causes Priam to start running.
# When Priam runs, it configures cassandra and starts it, either replacing a lost node or booting a new one.
#
target_path = "#{node[:tomcat][:webapp_dir]}/Priam.war"
bash "install_priam_war" do
  code lazy { <<-EOL
  cp #{priam_source_cache_path}/priam-web/build/libs/priam-web-#{node[:cassandra][:priam][:source][:version]}.war #{target_path}
    EOL
  }
  not_if { File.exist? target_path }
end