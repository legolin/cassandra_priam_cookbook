# Create a RAID array on all available instance store disks
#
# Credits: Joe Miller, https://gist.github.com/joemiller/6049831
# 
instance_metadata_url = "http://169.254.169.254/2012-01-12"

# Install required packages for RAID
%w'mdadm xfs xfsprogs'.each do |pkg|
  package pkg do
    action :install
  end
end

# Create /data directory
directory '/data' do
  action :create
end


# Detect drive scheme (xvdb or sdb)
if node.filesystem.keys.include?('/dev/xvda1')
  drive_scheme = 'xvd'
else
  drive_scheme = 'sd'
end
log("Detected drive naming scheme: #{drive_scheme}")

# Detect the ephemeral drives we have
#   - Covert the drive name returned from the API to the drive_scheme if necessary
#   - Verify that a matching device is available in /dev/

ephemerals = node.ec2.keys.select{|k| k.include?('ephemeral') }.collect{|key| node.ec2[key] }
log "Ephemeral disks reported: #{ephemerals.join(', ')}."

ephemerals = ephemerals.collect do |device_name|
  device_name = device_name.gsub('sd', drive_scheme)
  device_path = "/dev/#{device_name}"
  ::File.exist?( device_path ) ? device_path : nil
end.compact

# Create RAID array if possible
if ephemerals.length > 1

  log "Actual ephemeral disks detected: #{ephemerals}"

  mount '/mnt' do
    device ephemerals.first
    action [:umount, :disable]
  end

  bash "create-ephemeral-raid-array" do
    user 'root'
    code <<-EOH
      yes | mdadm --create /dev/md0 --level=0 --raid-devices=#{ephemerals.length} #{ephemerals.join(' ')}
      mdadm --detail --scan >> /etc/mdadm/mdadm.conf
      mkfs -t xfs /dev/md0
    EOH
    not_if 'grep md0 /etc/mdadm/mdadm.conf'
  end

  mount '/data' do
    device '/dev/md0'
    fstype 'xfs'
    options 'noatime'
    action [ :mount, :enable ]
  end

elsif ephemerals.length == 1
  
  mount '/mnt' do
    device ephemerals.first
    action [:umount, :disable]
  end

  mount '/data' do
    device ephemerals.first
    options 'noatime,nobootwait'
    action [ :mount, :enable ]
  end

else
  log "No ephemeral disks detected.  Skipping RAID."
end 
