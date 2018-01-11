
## Installing VerneMQ
VerneMQ is a very solid MQTT server written in Erlang. It runs fine on Raspbian, but we need to build it from source and apply a tiny tweak. Another popular MQTT server is Mosquitto, but we have had some odd silent crashes using Mosquitto which may be related to issues in libwebsocket (and not in Mosquitto itself), but either way I prefer VerneMQ. **Any MQTT server would of course work just fine.**

### Installing Erlang
We use proper Debian repositories for this:

    wget https://packages.erlang-solutions.com/erlang-solutions_1.0_all.deb
    sudo dpkg -i erlang-solutions_1.0_all.deb
    sudo apt-get update
    sudo apt-get install erlang

### Building VerneMQ
Building VerneMQ is easy:

    git clone git://github.com/erlio/vernemq
    cd vernemq
    make rel

...giving up on VerneMQ for a while, issues to make it on Raspbian Jessie at least...