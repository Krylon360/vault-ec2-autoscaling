#!/bin/bash -eux

add-apt-repository 'deb http://archive.ubuntu.com/ubuntu $(lsb_release -sc) main universe restricted multiverse'
apt-get update
apt-get -y upgrade
apt-get -y install python-pip
pip install awscli

mv /tmp/ha-nat.sh /usr/local/bin/ha-nat.sh
