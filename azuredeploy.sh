#!/bin/sh

# This script can be found on https://github.com/Azure/azure-quickstart-templates/blob/master/slurm/azuredeploy.sh
# This script is part of azure deploy ARM template
# This script assumes the Linux distribution to be Ubuntu (or at least have apt-get support)
# This script will install SLURM on a Linux cluster deployed on a set of Azure VMs
LOG=/tmp/azuredeploy.log.$$

{
# Basic info
date
whoami

# Log params passed to this script.  You may not want to do this since it includes the password for the slurm admin
echo $@

# Usage
if [ "$#" -ne 11 ]; then
  echo "Usage: $0 MASTER_NAME MASTER_IP MASTER_AS_WORKER WORKER_NAME WORKER_IP_BASE WORKER_IP_START NUM_OF_VM ADMIN_USERNAME ADMIN_PASSWORD NUM_OF_DATA_DISKS TEMPLATE_BASE" >> /tmp/azuredeploy.log.$$
  exit 1
fi

# Preparation steps - hosts and ssh
###################################

# Parameters
MASTER_NAME=${1}
MASTER_IP=${2}
MASTER_AS_WORKER=${3}
WORKER_NAME=${4}
WORKER_IP_BASE=${5}
WORKER_IP_START=${6}
NUM_OF_VM=${7}
ADMIN_USERNAME=${8}
ADMIN_PASSWORD=${9}
NUM_OF_DATA_DISKS=${10}
TEMPLATE_BASE=${11}

# Get latest packages
sudo apt-get update

# Create a cluster wide NFS share directory. Format and mount the data disk on master and install NFS
sudo sh -c "mkdir /data"
if [ $NUM_OF_DATA_DISKS -eq 1 ]; then
  sudo sh -c "mkfs -t ext4 /dev/sdc"
  echo "UUID=`blkid -s UUID /dev/sdc | cut -d '"' -f2` /data ext4  defaults,discard 0 0" | sudo tee -a /etc/fstab
else
  sudo apt-get install lsscsi -y
  DEVICE_NAME_STRING=
  for device in `lsscsi |grep -v "/dev/sda \|/dev/sdb \|/dev/sr0 " | cut -d "/" -f3`; do 
   DEVICE_NAME_STRING_TMP=`echo /dev/$device`
   DEVICE_NAME_STRING=`echo $DEVICE_NAME_STRING $DEVICE_NAME_STRING_TMP`
  done
  sudo mdadm --create /dev/md0 --level 0 --raid-devices=$NUM_OF_DATA_DISKS $DEVICE_NAME_STRING
  sudo sh -c "mkfs -t ext4 /dev/md0"
  echo "UUID=`blkid -s UUID /dev/md0 | cut -d '"' -f2` /data ext4  defaults,discard 0 0" | sudo tee -a /etc/fstab
fi

sudo sh -c "mount /data"
sudo sh -c "chown -R $ADMIN_USERNAME /data"
sudo sh -c "chgrp -R $ADMIN_USERNAME /data"
sudo apt-get install nfs-kernel-server -y
echo "/data 10.0.0.0/16(rw)" | sudo tee -a /etc/exports
sudo systemctl restart nfs-kernel-server

# Create a shared folder on /data to store files used by the installation process
sudo -u $ADMIN_USERNAME sh -c "rm -rf /data/tmp"
sudo -u $ADMIN_USERNAME sh -c "mkdir /data/tmp"

# Create a shared environment variables file on /data and reference it in the login .bashrc file
sudo rm /data/shared-bashrc
sudo -u $ADMIN_USERNAME touch /data/shared-bashrc
echo "source /data/shared-bashrc" | sudo -u $ADMIN_USERNAME tee -a /home/$ADMIN_USERNAME/.bashrc 

# Create Workers NFS client install script and store it on /data
sudo rm /data/tmp/workerNfs.sh
sudo touch /data/tmp/workerNfs.sh
sudo chmod u+x /data/tmp/workerNfs.sh
echo "sudo sh -c \"mkdir /data\"" | sudo tee -a /data/tmp/workerNfs.sh
echo "sudo apt-get install nfs-common -y" | sudo tee -a /data/tmp/workerNfs.sh
echo "echo \"$MASTER_NAME:/data /data nfs rw,hard,intr 0 0\" | sudo tee -a /etc/fstab " | sudo tee -a /data/tmp/workerNfs.sh
echo "sudo sh -c \"mount /data\"" | sudo tee -a /data/tmp/workerNfs.sh

# Update master node hosts file
echo $MASTER_IP $MASTER_NAME >> /etc/hosts
echo $MASTER_IP $MASTER_NAME > /data/tmp/hosts

# Update ssh config file to ignore unknown hosts
# Note all settings are for $ADMIN_USERNAME, NOT root
sudo -u $ADMIN_USERNAME sh -c "mkdir /home/$ADMIN_USERNAME/.ssh/;echo Host worker\* > /home/$ADMIN_USERNAME/.ssh/config; echo StrictHostKeyChecking no >> /home/$ADMIN_USERNAME/.ssh/config; echo UserKnownHostsFile=/dev/null >> /home/$ADMIN_USERNAME/.ssh/config"

# Generate a set of sshkey under /honme/$ADMIN_USERNAME/.ssh if there is not one yet
if ! [ -f /home/$ADMIN_USERNAME/.ssh/id_rsa ]; then
    sudo -u $ADMIN_USERNAME sh -c "ssh-keygen -f /home/$ADMIN_USERNAME/.ssh/id_rsa -t rsa -N ''"
fi

# Install sshpass to automate ssh-copy-id action
sudo apt-get install sshpass -y

# Loop through all worker nodes, update hosts file and copy ssh public key to it
# The script make the assumption that the node is called %WORKER+<index> and have
# static IP in sequence order
i=0
while [ $i -lt $NUM_OF_VM ]
do
   workerip=`expr $i + $WORKER_IP_START`
   echo 'I update host - '$WORKER_NAME$i
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> /etc/hosts
   echo $WORKER_IP_BASE$workerip $WORKER_NAME$i >> /data/tmp/hosts
   TRIAL=0
   echo 'checking if the ssh is up'
    until nc -w 5 -z $WORKER_NAME$i 22;
    do
	echo 'to wait 60 sec'
	sleep 60
	TRIAL=`expr $TRIAL + 1`
	if [ $TRIAL -eq 5 ]; then
	    echo 'give up'
	    break
	fi
    done
   sudo -u $ADMIN_USERNAME sh -c "sshpass -p '$ADMIN_PASSWORD' ssh-copy-id $WORKER_NAME$i"
   i=`expr $i + 1`
done

# Install SLURM on master node
###################################

# Install the package
sudo apt-get update
sudo chmod g-w /var/log # Must do this before munge will generate key
sudo apt-get install slurm-llnl parallel -y

# Make a slurm spool directory
sudo mkdir /var/spool/slurm
sudo chown slurm /var/spool/slurm

# Download slurm.conf and fill in the node info
SLURMCONF=/data/tmp/slurm.conf
wget $TEMPLATE_BASE/slurm.template.conf -O $SLURMCONF
sed -i -- 's/__MASTERNODE__/'"$MASTER_NAME"'/g' $SLURMCONF
if [ "$MASTER_AS_WORKER" = "True" ];then
  sed -i -- 's/__MASTER_AS_WORKER_NODE__,/'"$MASTER_NAME,"'/g' $SLURMCONF
else
  sed -i -- 's/__MASTER_AS_WORKER_NODE__,/'""'/g' $SLURMCONF
fi
lastvm=`expr $NUM_OF_VM - 1`
sed -i -- 's/__WORKERNODES__/'"$WORKER_NAME"'[0-'"$lastvm"']/g' $SLURMCONF

WORKER_CPUS=`sudo -u $ADMIN_USERNAME ssh worker0 '( nproc --all )'`
sed -i -- 's/__NODECPUS__/'"CPUs=`echo $WORKER_CPUS`"'/g' $SLURMCONF
#sed -i -- 's/__NODECPUS__/'"CPUs=`nproc --all`"'/g' $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1

WORKER_RAM=`sudo -u $ADMIN_USERNAME ssh worker0 '( free -m )' | awk '/Mem:/{print $2}'`
sed -i -- 's/__NODERAM__/'"RealMemory=`echo $WORKER_RAM`"'/g' $SLURMCONF
#sed -i -- 's/__NODERAM__/'"RealMemory=`free -m | awk '/Mem:/{print $2}'`"'/g' $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1

WORKER_THREADS=`sudo -u $ADMIN_USERNAME ssh worker0 '( lscpu|grep Thread|cut -d ":" -f 2 )'| awk '{$1=$1;print}'`
sed -i -- 's/__NODETHREADS__/'"ThreadsPerCore=`echo $WORKER_THREADS`"'/g' $SLURMCONF
#sed -i -- 's/__NODETHREADS__/'"ThreadsPerCore=`lscpu|grep Thread|cut -d ":" -f 2|awk '{$1=$1;print}'`"'/g' $SLURMCONF >> /tmp/azuredeploy.log.$$ 2>&1

sudo cp -f $SLURMCONF /etc/slurm-llnl/slurm.conf
sudo chown slurm /etc/slurm-llnl/slurm.conf
sudo chmod o+w /var/spool # Write access for slurmctld log. Consider switch log file to another location
sudo -u slurm /usr/sbin/slurmctld # Start the master daemon service
sudo munged --force # Start munged
sudo slurmd # Start the node

# Install slurm on all nodes by running apt-get
# Also push munge key and slurm.conf to them
echo "Prepare the local copy of munge key" 
mungekey=/data/tmp/munge.key
sudo cp -f /etc/munge/munge.key $mungekey
echo "Done copying munge" 
sudo chown $ADMIN_USERNAME $mungekey
ls -la $mungekey 

# Get and install shared software on /data
#echo "PATH=\$PATH:/data/canu/canu-1.6/Linux-amd64/bin" | sudo -u $ADMIN_USERNAME tee -a /data/shared-bashrc

# Create and deploy assets to worker nodes
echo "Start looping all workers" 

sudo cat > /data/tmp/workerinit.sh << 'ENDSSH1'
   sudo /tmp/workerNfs.sh
   sudo echo "source /data/shared-bashrc" | sudo -u $USER tee -a /home/$USER/.bashrc
   sudo sh -c "cat /data/tmp/hosts >> /etc/hosts"
   sudo chmod g-w /var/log
   sudo mkdir /var/spool/slurm
   sudo chown slurm /var/spool/slurm
   sudo apt-get update
   sudo apt-get install slurm-llnl -y
   sudo cp -f /tmp/munge.key /etc/munge/munge.key
   sudo chown munge /etc/munge/munge.key
   sudo chgrp munge /etc/munge/munge.key
   sudo /usr/sbin/munged --force # ignore egregrious security warning
   sudo cp -f /data/tmp/slurm.conf /etc/slurm-llnl/slurm.conf
   sudo chown slurm /etc/slurm-llnl/slurm.conf
   sudo slurmd
ENDSSH1
sudo chmod u+x /data/tmp/workerinit.sh


i=0
while [ $i -lt $NUM_OF_VM ]
do
   worker=$WORKER_NAME$i

   echo "SCP to $worker"  
   # copy NFS mount script over
   sudo -u $ADMIN_USERNAME scp /data/tmp/workerNfs.sh $ADMIN_USERNAME@$worker:/tmp/workerNfs.sh
   # small hack: munge.key has permission problems when copying from NFS drive.  Fix this later
   sudo -u $ADMIN_USERNAME scp $mungekey $ADMIN_USERNAME@$worker:/tmp/munge.key
   
   sudo -u $ADMIN_USERNAME scp /data/tmp/workerinit.sh $ADMIN_USERNAME@$worker:/tmp/workerinit.sh
   
   i=`expr $i + 1`
done

echo "Remote execute on worker" 
parallel -j 0 --delay 0.25 --tag "sudo -u $ADMIN_USERNAME ssh $ADMIN_USERNAME@{} /tmp/workerinit.sh" ::: $(cat /etc/hosts | grep $WORKER_NAME | cut -f2 -d" ")


# Remove temp files on master
#rm -f $mungekey
#sudo rm -f /data/tmp/*

# Write a file called done in the $ADMIN_USERNAME home directory to let the user know we're all done
echo "azuredeploy.sh done"
sudo -u $ADMIN_USERNAME touch /home/$ADMIN_USERNAME/done
} 2>&1 | tee $LOG
exit 0
