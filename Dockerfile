FROM ubuntu:15.04
MAINTAINER Marcel Wiget

# Install enough packages to compile snabb and qemu
RUN apt-get update
RUN apt-get install -y --no-install-recommends bridge-utils tmux telnet net-tools netcat expect iproute2 numactl

# Download and compile snabb and qemu, then cleanup
# qemu: Official build doesn't support reconnects, use the one from snabb instead
# snabb: Using fork from mwiget until pull request #604 is resolved: 
# See https://github.com/SnabbCo/snabbswitch/pull/604
RUN apt-get install -y --no-install-recommends build-essential git ca-certificates \
  libqtcore4 libusbredirhost1 qtcore4-l10n spice-client-glib-usb-acl-helper \
  glib-2.0 libglib2.0-dev libsdl1.2debian libsdl1.2-dev libaio-dev libcap-dev \
  libattr1-dev libpixman-1-dev libncurses5 libncurses5-dev libspice-server1 \
  && git clone https://github.com/mwiget/snabbswitch.git \
  && cd snabbswitch && make -j && make install && make clean \
  && git clone -b v2.1.0-vhostuser --depth 50 https://github.com/SnabbCo/qemu && \
  cd qemu && ./configure --target-list=x86_64-softmmu && make -j && make install \
  && apt-get purge -y build-essential git ca-certificates libncurses5-dev glib-2.0 \
  && apt-get autoremove -y \
  && rm -rf /var/lib/apt/lists/* /snabbswitch /qemu

COPY launch.sh readme.txt /

ENTRYPOINT ["/launch.sh"]

CMD ["vmx"]
