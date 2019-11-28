#!/bin/bash

set -e

# To be run as "ubuntu" user w/ sudo access

sudo apt-get -yqq install apache2-utils libjemalloc-dev libtcmalloc-minimal4 openjdk-8-jdk

# Passenger install for comparing app servers
sudo apt-get install -y dirmngr gnupg
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7
sudo apt-get install -y apt-transport-https ca-certificates

sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger xenial main > /etc/apt/sources.list.d/passenger.list'
sudo apt-get update

sudo apt-get install -y passenger

# Wrk
cd /home/ubuntu
git clone https://github.com/wg/wrk.git
cd wrk
make
# Install wrk binary into /usr/local/bin
sudo cp wrk /usr/bin/

# You know what sucks? Having a huge, benchmark-busting cron job start at
# a random-ish time, screwing up all your results.
sudo apt-get remove -y unattended-upgrades
