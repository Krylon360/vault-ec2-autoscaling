#!/bin/bash -eux

apt-get update
apt-get upgrade -y
apt-get update
apt-get install -y curl jq unzip
