#!/bin/bash
#
echo "Juniper Networks vMX Docker Container (unsupported prototype)"
echo ""

set -e	#  Exit immediately if a command exits with a non-zero status.

#export qemu=/qemu/x86_64-softmmu/qemu-system-x86_64
qemu=/usr/local/bin/qemu-system-x86_64
snabb=/usr/local/bin/snabb  # only used for Intel 82599 10GE ports

# mount hugetables, remove directory if this isn't possible due
# to lack of privilege level. A check for the diretory is done further down
mkdir /hugetlbfs && mount -t hugetlbfs none /hugetlbfs || rmdir /hugetlbfs

# check that we are called with enough privileges and env variables set
if [ ! -d "/hugetlbfs" -o ! -d "/u" -o -z "$TAR" -o -z "$DEV" ]; then
  cat readme.txt
  exit 1
fi

echo -n "Checking system for hugepages ..."
HUGEPAGES=`cat /proc/sys/vm/nr_hugepages`
if [ "2500" -gt "$HUGEPAGES" ]; then
  echo ""
  echo ""
  echo "ERROR: Not enough hugepages reserved!"
  echo ""
  echo "Please reserve at least 2500 hugepages to run vMX."
  echo "You can do this as root with the following command:"
  echo ""
  echo "# echo 5000 > /proc/sys/vm/nr_hugepages"
  echo ""
  echo "Make it permanent by adding 'hugepages=5000' to GRUB_CMDLINE_LINUX_DEFAULT"
  echo "in /etc/default/grub, followed by running 'update-grub'"
  echo ""
  exit 1
fi
echo " ok ($HUGEPAGES)"

vcpmem=2000
MEM="${MEM:-5000}"
VCPU="${VCPU:-5}"

if [ ! -e "/u/$TAR" ]; then
  echo "Please set env TAR with a URL to download vmx-<rel>.tgz:"
  echo "docker run .... --env TAR=\"\" ..."
  echo "You can download the latest release from Juniper Networks at"
  echo "http://www.juniper.net/support/downloads/?p=vmx"
  echo "(Requires authentication)"
  exit 1
fi

if [ ! -z "`cat /proc/cpuinfo|grep f16c|grep fsgsbase`" ]; then
  CPU="-cpu SandyBridge,+rdrand,+fsgsbase,+f16c"
  echo "CPU supports high performance PFE image"
else
  CPU=""
  echo "CPU doesn't supports high performance PFE image, using lite version"
fi

if [ ! -z "$CPU" -a  ".lite" != ".$PFE" ]; then
  echo "Using high performance PFE image (specify --env PFE=\"lite\" otherwise)"
else
  echo "Using PFE lite image (remove --env PFE otherwise)"
fi

#---------------------------------------------------------------------------
function cleanup {

  echo ""
  echo ""
  echo "vMX terminated."
  echo ""
  echo "cleaning up interfaces and bridges ..."

  echo "Removing physical interfaces from bridges ..."
  for INT in $INTS; do
    BRIDGE=`echo "$INT"|cut -d: -f1`
    INTERFACE=`echo "$INT"|cut -d: -f2`
    $(delif_from_bridge $BRIDGE $INTERFACE)
  done
  echo "Removing tap interfaces from bridges ..."
  for TAP in $TAPS; do
    BRIDGE=`echo "$TAP"|cut -d: -f1`
    TAP=`echo "$TAP"|cut -d: -f2`

    echo "delete interface $TAP from $BRIDGE"
    $(delif_from_bridge $BRIDGE $TAP)

    echo "delete tap interface $TAP"
    $(delete_tap_if $TAP) || echo "WARNING: trouble deleting tap $TAP"
  done

  echo "Deleting bridges ..."
  for BRIDGE in $BRIDGES; do
    $(delete_bridge $BRIDGE)
  done

  echo "Deleting fxp0 and internal links and bridges"
  if [ ! -z "$BRINT" ]; then
    $(delif_from_bridge $BRINT $VCPINT)
    $(delete_tap_if $VCPINT) || echo "WARNING: trouble deleting tap $VCPINT"
    $(delete_tap_if $VFPINT) || echo "WARNING: trouble deleting tap $VFPINT"
    $(delete_bridge $BRINT)
  fi

  if [ ! -z "$BRMGMT" ]; then
    if [ ! -z "$VCPMGMT" ]; then
      $(delif_from_bridge $BRMGMT $VCPMGMT)
      $(delete_tap_if $VCPMGMT) || echo "WARNING: trouble deleting tap $VCPMGMT"
    fi
    if [ ! -z "$VFPMGMT" ]; then
      $(delif_from_bridge $BRMGMT $VFPMGMT)
      $(delete_tap_if $VFPMGMT) || echo "WARNING: trouble deleting tap $VFPMGMT"
    fi
  fi
  echo "done"

  if [ ! -z "$PCIDEVS" ]; then
    echo "Giving 10G ports back to linux kernel"
    for PCI in $PCIDEVS; do
      echo -n "$PCI" > /sys/bus/pci/drivers/ixgbe/bind
    done
  fi
  trap - EXIT SIGINT SIGTERM
  exit 0
}
#---------------------------------------------------------------------------

trap cleanup EXIT SIGINT SIGTERM

function create_bridge {
  if [ -z "`brctl show|grep $11`" ]; then
    brctl addbr $1
    ip link set $1 up
  fi
}

function addif_to_bridge {
  brctl addif $1 $2
}

function delif_from_bridge {
  brctl delif $1 $2
}

function delete_bridge {
  if [ "2" == "`brctl show $1|wc -l`" ]; then
    ip link set $1 down
    brctl delbr $1
  fi
}

function create_tap_if {
  ip tuntap add dev $1 mode tap
  ip link set $1 up promisc on
}

function delete_tap_if {
  ip tuntap del mode tap dev $1
}

function pci_node {
  case "$1" in
    *:*:*.*)
      cpu=$(cat /sys/class/pci_bus/${1%:*}/cpulistaffinity | cut -d "-" -f 1)
      numactl -H | grep "cpus: $cpu" | cut -d " " -f 2
      ;;
    *)
      echo $1
      ;;
  esac
}


# Create unique 4 digit ID used for this vMX in interface names
ID=`printf '%02x%02x' $[RANDOM%256] $[RANDOM%256]`
N=0	# added to each tap interface to make them unique

# Check if we run with --net=host or not by checking the existense of
# the bridge docker0:

if [ -z "`ifconfig docker0 >/dev/null 2>/dev/null && echo notfound`" ]; then
  echo "WARNING: Running without --net=host. No network based fxp0 access and only 10GE interfaces supported"
else
  BRMGMT="docker0"
fi

# Create tap interfaces for mgmt and internal connection
VCPMGMT="vcpm$ID$N"
N=$((N + 1))
$(create_tap_if $VCPMGMT)

VCPINT="vcpi$ID$N"
N=$((N + 1))
$(create_tap_if $VCPINT)

VFPMGMT="vfpm$ID$N"
N=$((N + 1))
$(create_tap_if $VFPMGMT)

VFPINT="vfpi$ID$N"
N=$((N + 1))
$(create_tap_if $VFPINT)

# Create internal bridge between VCP and VFP
BRINT="brint$ID"
$(create_bridge $BRINT)

# Add internal tap interface to internal bridge
$(addif_to_bridge $BRINT $VCPINT)
$(addif_to_bridge $BRINT $VFPINT)

# Add external (mgmt) tap interfaces to docker0
if [ ! -z "$BRMGMT" ]; then
  $(addif_to_bridge $BRMGMT $VCPMGMT)
  $(addif_to_bridge $BRMGMT $VFPMGMT)
fi

port_n=0	# added to each tap interface to make them unique

# =======================================================
# check the list of interfaces provided in --env DEV=
# to keep track of the bridges and tap interfaces
# for the data ports for cleanup before exiting

BRIDGES=""
TAPS=""
INTS=""
NETDEVS=""    # build netdev list for VFP qemu
PCIDEVS=""

echo "Building virtual interfaces and bridges ..."

for DEV in $DEV; do # ============= loop thru interfaces start

  # check if we have been given a bridge or interface
  # If its an interface, we need to first create a unique bridge
  # followed by creating a tap interface and place the tap and
  # interface in it.
  # If its a bridge, we simply create a tap interface and add it
  # to the bridge

  INT=""
  BRIDGE=""

  # check if the interface given looks like a PCI address
  # Right now I simply check for length == 12. Probably needs
  # a more sophisticated check to avoid confusion with long bridge or
  # interface names

  if [ "12" -eq "${#DEV}" ]; then
    # cool. We got a PCI address. Lets check if its valid
    if [ -L /sys/bus/pci/drivers/ixgbe/$DEV ]; then
      echo "$DEV is a supported Intel 82599-based 10G port."
      # add $DEV to list
      PCIDEVS="$PCIDEVS $DEV"
      macaddr=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
      NETDEVS="$NETDEVS -chardev socket,id=char$port_n,path=./xe$port_n.socket,server \
        -netdev type=vhost-user,id=net$port_n,chardev=char$port_n \
        -device virtio-net-pci,netdev=net$port_n,mac=$macaddr"

      cat > xe${port_n}.cfg <<EOF
return {
  {
    port_id = "xe${port_n}",
    mac_address = nil
  }
}
EOF
      node=$(pci_node $DEV)
      numactl="numactl --cpunodebind=$node --membind=$node"
      cat > launch_snabb_xe${port_n}.sh <<EOF
#!/bin/bash
while :
do
  $numactl $snabb snabbnfv traffic -k 10 -D 0 $DEV xe${port_n}.cfg %s.socket
  sleep 10
done

EOF
      chmod a+rx launch_snabb_xe${port_n}.sh
      port_n=$(($port_n + 1))
    else
      echo "Error: $DEV isn't an Intel 82599-based 10G port!"
      exit 1
    fi

  else

    TAP="ge$ID$port_n"
    port_n=$(($port_n + 1))
    $(create_tap_if $TAP)

    if [ -z "`ifconfig $DEV > /dev/null 2>/dev/null || echo found`" ]; then
      # check if its eventually an existing bridge
      echo "interface $DEV found"
      if [ ! -z "`brctl show $DEV 2>&1 | grep \"No such device\"`" ]; then
        INT=$DEV # nope, we have a physical interface here
        echo "$DEV is a physical interface"
      else
        echo "$DEV is an existing bridge"
        BRIDGE="$DEV"
      fi
    else
      # we know now $DEV is or will be a bridge. Check if it exists
      # already
      BRIDGE=$DEV
      if [ ! -z "`brctl show $DEV 2>&1 | grep \"No such device\"`" ]; then
        # doesn't exist yet. Lets create it
        echo "need to create bridge $BRIDGE"
        $(create_bridge $BRIDGE)
      fi
    fi

    if [ -z "$BRIDGE" ]; then
      BRIDGE="br$ID$port_n"
      $(create_bridge $BRIDGE)
    fi

#    echo "DEV=$DEV INT=$INT BRIDGE=$BRIDGE TAP=$TAP"

    $(addif_to_bridge $BRIDGE $TAP)

    if [ ! -z "$INT" ]; then
      $(addif_to_bridge $BRIDGE $INT)
    fi

    # track what we use for cleanup before exit
    BRIDGES="$BRIDGES $BRIDGE"
    TAPS="$TAPS $BRIDGE:$TAP"
    if [ ! -z "$INT" ]; then
      INTS="$INTS $BRIDGE:$INT"
    fi

    macaddr=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
    NETDEVS="$NETDEVS -netdev tap,id=net$port_n,ifname=$TAP,script=no,downscript=no \
        -device virtio-net-pci,netdev=net$port_n,mac=$macaddr"

  fi

done
# ===================================== loop thru interfaces done

echo "=================================="
echo "BRIDGES: $BRIDGES"
echo "TAPS:    $TAPS"
echo "INTS:    $INTS"
echo "PCIDEVS: $PCIDEVS"
echo "=================================="
echo "vPFE using ${MEM}MB and $VCPU vCPUs"
echo "=================================="

echo -n "extracting VM's from $TAR ... "
tar -zxf /u/$TAR -C /tmp/ --wildcards vmx*/images/*img
echo ""

VCPIMAGE="`ls /tmp/vmx-*/images/jinstall64-vmx*img`"
HDDIMAGE="`ls /tmp/vmx-*/images/vmxhdd.img`"
VFPIMAGE="`ls /tmp/vmx-*/images/vPFE-lite-*img`"

# This will allow the use of the high performance image if
if [ ! -z "$CPU" -a  ".lite" != ".$PFE" ]; then
  VFPIMAGE="`ls /tmp/vmx-*/images/vPFE-2*img`"
fi

if [ ! -f $VCPIMAGE ]; then
  echo "Can't find jinstall64-vmx*img in tar file"
  exit 1
fi

if [ ! -f $VFPIMAGE ]; then
  echo "Can't find vPFE-lite*img in tar file"
  exit 1
fi

if [ ! -f $HDDIMAGE ]; then
  echo "Can't find vmxhdd*img in tar file"
  exit 1
fi

echo "VCP image: $VCPIMAGE"
echo "VFP image: $VFPIMAGE"
echo "hdd image: $HDDIMAGE"

if [ -z "DEV" ]; then
  echo "Please set env DEV with list of interfaces or bridges:"
  echo "docker run .... --env DEV=\"eth1 br5 \""
  exit 1
fi


tmux_session="vmx$ID"

# Launch Junos Control plane virtual image in the background and
# connect to the console via telnet port 8008 if we have a config to
# send to it. Then open a telnet session to the console as the first
# tmux session, so its the main session a user see's.

macaddr1=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
macaddr2=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
vcp_pid="/var/tmp/vcp-$macaddr1.pid"
vcp_pid=$(echo $vcp_pid | tr ":" "-")


RUNVCP="$qemu -M pc -smp 1 --enable-kvm -cpu host -m $vcpmem \
  -drive if=ide,file=$VCPIMAGE -drive if=ide,file=$HDDIMAGE \
  -device cirrus-vga,id=video0,bus=pci.0,addr=0x2 \
  -netdev tap,id=tc0,ifname=$VCPMGMT,script=no,downscript=no \
  -device e1000,netdev=tc0,mac=$macaddr1 \
  -netdev tap,id=tc1,ifname=$VCPINT,script=no,downscript=no \
  -device virtio-net-pci,netdev=tc1,mac=$macaddr2 \
  -chardev socket,id=charserial0,host=127.0.0.1,port=8008,telnet,server,nowait \
  -device isa-serial,chardev=charserial0,id=serial0 \
  -pidfile=/tmp/$vcp_pid -vnc 127.0.0.1:1 -daemonize"

echo "$RUNVCP" > runvcp.sh
chmod a+rx runvcp.sh

./runvcp.sh # launch VCP in the background

echo "waiting for login prompt ..."
/usr/bin/expect <<EOF
set timeout -1
spawn telnet localhost 8008
expect "login:"
EOF

# if we have a config file, use it to log in an set
if [ -e "/u/$CFG" ]; then
  printf "\033c"  # clear screen
  echo "Using config file /u/$CFG to provision the vMX ..."
  cat /u/$CFG | nc -t -i 1 -q 1 127.0.0.1 8008
fi

tmux new-session -d -n "vcp" -s $tmux_session "telnet localhost 8008"

# Launch VFP

macaddr1=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
macaddr2=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
vfp_pid="/var/tmp/vfp-$macaddr1.pid"
vfp_pid=$(echo $vfp_pid | tr ":" "-")

# launch snabb drivers, if any
for file in launch_snabb_xe*.sh
do
  tmux new-window -a -d -n "${file:13:3}" -t $tmux_session ./$file
done

# we borrow the last $numactl in case of 10G ports. If there wasn't one
# then this will be simply empty
RUNVFP="$numactl $qemu -M pc -smp $VCPU --enable-kvm $CPU -m $MEM -numa node,memdev=mem \
  -object memory-backend-file,id=mem,size=${MEM}M,mem-path=/hugetlbfs,share=on \
  -drive if=ide,file=$VFPIMAGE \
  -netdev tap,id=tf0,ifname=$VFPMGMT,script=no,downscript=no \
  -device virtio-net-pci,netdev=tf0,mac=$macaddr1 \
  -netdev tap,id=tf1,ifname=$VFPINT,script=no,downscript=no \
  -device virtio-net-pci,netdev=tf1,mac=$macaddr2 -pidfile=$vfp_pid \
  $NETDEVS -nographic"

echo "$RUNVFP" > runvfp.sh
chmod a+rx runvfp.sh

tmux new-window -a -d -n "vfp" -t $tmux_session ./runvfp.sh

tmux new-window -a -d -n "shell" -t $tmux_session "bash"

# DON'T detach from tmux when running the container! Use docker's ^P^Q to detach
tmux attach

# ==========================================================================
# User terminated tmux, lets kill all VM's too

echo "killing all VM's and snabb drivers ..."
kill `cat $vcp_pid` || true
kill `cat $vfp_pid` || true
pkill snabb || true

echo "waiting for qemu having terminated ..."
while  true;
do
  if [ "1" == "`ps ax|grep qemu|wc -l`" ]; then
    break
  fi
  sleep 2
done

exit  # this will call cleanup, thanks to trap set earlier (hopefully)
