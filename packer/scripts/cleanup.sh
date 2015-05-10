#!/bin/bash -eux

apt-get -y autoremove
apt-get -y clean

shred -u /etc/ssh/*_key /etc/ssh/*_key.pub
