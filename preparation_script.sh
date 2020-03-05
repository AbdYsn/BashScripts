#!/bin/bash

#set -e
set -x

parse_conf(){
   param=$1
   if [[ -f local.conf ]]
   then
      echo `grep -x $param"=.*" local.conf | cut -d"=" -f 2`
   fi
}

master_ip=`parse_conf master_ip`
master_hostname=`parse_conf master_hostname`
netmask=`parse_conf netmask`
host_ip=`parse_conf host_ip`
hostname=`parse_conf hostname`
interface=`parse_conf interface`
hostname_change_flag=`parse_conf change_machine_hostname`

##################################################
##################################################
##################   input   #####################
##################################################
##################################################

while test $# -gt 0; do
  case "$1" in

   --interface | -i)
      interface=$2
      shift
      shift
      ;;

   --hostname)
      hostname=$2
      shift
      shift
      ;;

   --master-hostname)
      master_hostname=$2
      shift
      shift
      ;;

   --ip)
      master_ip=$2
      shift
      shift
      ;;

   --netmask)
      netmask=$2
      shift
      shift
      ;;

   --set-hostname)
      hostname_change_flag="true"
      shift
      ;;

   --help | -h)
      echo "
prepration_script [options] --ip <master ip> --master-hostname <master hostname> --hostname <hostname of host> --netmask <network netmask>\
 --vfs-num <number of vfs to create> --interface <the interface to create the vfs on>: prepare the host by initializing some global\
  variables and setting the hostname.

options:
 
	--interface | -i) <interface>			The name to be used to rename the netdev at the specified pci address.
   
	--hostname) <host hostname>			The hostname of the current host

	--set-hostname)					A flag used if you want to change the hostname of the machine to the specified host name

	--master-hostname) <master hostname>		The hostname of the master

	--ip) <ip of the master node>			The ip of the master node

	--netmask) <netmask>				The cluster network netmask, used to configure the interface.

"
      exit 0
      ;;
   
   *)
      echo "No such option!!"
      echo "Exitting ...."
      exit 1
  esac
done

exec 1> >(logger -s -t $(basename $0)) 2>&1

##################################################
##################################################
##############   validation   ####################
##################################################
##################################################

if [[ -z "$interface" ]]
then
   echo "The interface was not provided !!!
   Please provide one using the option --interface
   for more informaton see the help menu --help or -h
   Exitting ...."
   exit 1
fi

if [[ -z $hostname ]]
then
   logger "The hostname was not provided !!!
   Will use the machine hostname
   you can provide one using the option --hostname"
   hostname=`hostname -f`
   logger "the hostname that will be used is: $hostname"
fi

if [[ -z $master_hostname ]]
then
   echo "The master hostname was not provided !!!
   Please provide one using the option --master-hostname
   for more informaton see the help menu --help or -h
   Exitting ...."
   exit 1
fi

if [[ -z $master_ip ]]
then
   echo "The master ip was not provided !!!
   Please provide one using the option --ip
   for more informaton see the help menu --help or -h
   Exitting ...."
   exit 1
fi

if [[ -z $netmask ]]
then
   echo "The netmask was not provided !!!
   Please provide one using the option --netmask
   for more informaton see the help menu --help or -h
   Exitting ...."
   exit 1
fi

my_path=`pwd`

if [[ -z "$host_ip" ]]
then
   host_ip=`ifconfig $interface | grep -o "inet [0-9.]* " | cut -d" " -f 2`
fi

if [[ -z "$host_ip" ]]
then
   echo "no ip on the provided interface, please make sure that the network\
    settings are correct !!!
   Please provide one using the option --interface
   for more informaton see the help menu --help or -h
   Exitting ...."
   exit 1
fi

##################################################
##################################################
###############   Functions   ####################
##################################################
##################################################


change_hostname(){  
old_hostname=`hostname`
if [[ "$old_hostname" != "$hostname" ]]
   then
      hostname_line="`grep $old_hostname /etc/hosts`"
      if [[ -n $hostname_line ]]
      then
         sed -i "s/$old_hostname/$hostname/g" /etc/hosts
      fi
      hostnamectl set-hostname $hostname
fi
}

hostname_add(){
   ip=$1
   local_hostname=$2
   if [[ -z "`grep $ip /etc/hosts`" ]]
   then
      echo "$ip $local_hostname" >> /etc/hosts
   else
      if [[ "`grep $ip /etc/hosts | cut -d\" \" -f 2`" != "$local_hostname" ]]
      then
         old_host="`grep $ip /etc/hosts | cut -d" " -f 2`"
         sed -i "s/$old_host/$local_hostname/g" /etc/hosts
      fi
   fi
}

gopath_check(){
change_content "$HOME/.bashrc" "KUBECONFIG" "/etc/kubernetes/admin.conf"
}

kubernetes_repo_check(){
   if [[ ! -f "/etc/yum.repos.d/kubernetes.repo" ]] || [[ -z `\
   gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg /etc/yum.repos.d/kubernetes.repo` ]]
   then
   sudo tee -a /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernets-stable]
name=Kuberenets
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-x86_64
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
  fi
}

system_args_check(){
   change_content "/etc/sysctl.conf" "net.ipv4.ip_forward" "1"
   change_content "/etc/sysctl.conf" "net.bridge.bridge-nf-call-iptables" "1"
   sysctl -p

   if [[ -n `swapon -s` ]]
   then
      swapoff -a
   fi

   swap_line_numbers="`grep -x -n "[^#]*swap.*" /etc/fstab | cut -d":" -f 1`"
   if [[ -n $swap_line_numbers ]]
   then
      for line_number in $swap_line_numbers;
      do
         sed -i "$line_number s/^/\#/g" /etc/fstab
      done
   fi

   if [[ `systemctl is-active firewalld` != "inactive" ]] 
   then 
      systemctl stop firewalld
   fi

   if [[ `systemctl is-enabled firewalld` != "disabled" ]] 
   then 
      systemctl disable firewalld
   fi
}

change_content(){
   file=$1
   content=$2
   new_value=$3
   amend="$4"
   file_content=`grep $content $file` 
   if [[ -z $file_content ]]
   then
      echo "$content=$new_value" >> $file
   elif [[ `cut -d"=" -f 2 <<< $file_content ` != "$new_value" ]] && [[ -z $amend ]]
   then
      sed -i s/"$content=[^ ]*"/"$content=$new_value"/g $file
   elif [[ ! `cut -d"=" -f 2 <<< $file_content ` =~ $new_value ]] && [[ -n $amend ]]
   then
      old_content=`grep -o "$content=[^ ]*" $file`
      sed -i s/"$old_content"/"$old_content$new_value"/g $file
   fi
}

##################################################
##################################################
###################   Main   #####################
##################################################
##################################################


hostname_add $master_ip $master_hostname
hostname_add $host_ip $hostname
if [[ $hostname_change_flag == "true" ]]
then
   change_hostname
fi

gopath_check
kubernetes_repo_check
system_args_check
echo "Please reboot the host"
