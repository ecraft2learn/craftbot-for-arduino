# Arduinobot

For making Arduino compilation and flashing into a service it turns out there have been numerous takes on this task over the years but today there are basically two reasonable paths we can take:

* Using the official Arduino IDE `arduino` and it's own CLI commands.
* Using the `arduino-builder` binary directly. The IDE internally calls this tool (that is written in Go) to compile a sketch. 

Other attempts to do this that are less optimal today are:
* Using a Makefile driven toolset like arduino-mk or Arduino-Makefile (not maintained by Arduino)
* Using inotool.org (no changes in 4 years, probably dead)

One can also mention the arduino-create-agent tool that Arduino also has created so that the serial ports of a machine are accessible over websockets:

> "we are using golang and cross compile on all available platforms (ARM, MacOS, Linux, Win) both 32 and 64 bits to create an agent. The agent can listen locally or remotely to allow you program your boards on the internet."

## Implementation
The Arduinobot is a small binary service that is run as a service on a Raspberry Pi, or other machine since it's cross platform. Arduinobot connects to an MQTT server and further configuration is picked up as a retained message on the topic `config`. Arduinobot then listens to the MQTT topics `verify` and `upload` in order to perform **compilation** and **flashing** jobs. Messages are in JSON format. It also listens for REST calls on a given port to perform the same kind of operations.

The actual work is performed by invoking either `arduino` or `arduino-builder`.

# Raspbian Stretch
Arduinobot is developed primarily for Raspbian. The latest stable is called **Stretch**, on Linux, [follow the instructions to put it on an sdcard](https://www.raspberrypi.org/documentation/installation/installing-images/linux.md).

In the end we will make **an automated script to build a complete sdcard** with Arduinobot, but for now this document describes the various steps to prepping it.

## Boot Rpi
Put a file called "ssh" onto the "boot" partition of the sdcard.

    touch /media/<myuser>/boot/ssh
    sudo umount /media/<blabla>

Insert into Rpi, connect ethernet wire, connect micro USB for power. Then when it boots you should be able to login:

    ssh pi@raspberrypi.local "raspberry"

And configure it:

    sudo raspi-config

* Expand filesystem (Advanced Options)
* Change hostname (if you wish)
* Enable SSH (under Interfacing options)
* Change timezone

Then reboot it and run:

    sudo apt-get update
    sudo apt-get upgrade

# Wifi
In order for the Raspberry to auto connect to a given wifi we need a bit of configuration. This is a bit problematic with Raspbian Stretch, but the following got it working.

Add the following lines to `/etc/network/interfaces`:

    allow-hotplug wlan0
    iface wlan0 inet manual
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf

Add your Wifi settings to `/etc/wpa_supplicant/wpa_supplicant.conf`:

    network={
        ssid="MyCoolWifi"
        psk="some-good-password"
    }

Hopefully this should then get the Raspberry to automatically connect to the Wifi upon boot.

# MQTT
Arduinobot can use any MQTT server, but an interesting use case is when the Raspberry Pi is a complete standalone solution, acting as an access point, and not connecting to any other network. In this case we run a local MQTT server on the Raspberry and for the moment we have chosen to use [Mosquitto](https://mosquitto.org/) and to get the latest we use their own repositories:

    wget http://repo.mosquitto.org/debian/mosquitto-repo.gpg.key
    sudo apt-key add mosquitto-repo.gpg.key

Then make the repository available to apt:

    cd /etc/apt/sources.list.d/
    sudo wget http://repo.mosquitto.org/debian/mosquitto-stretch.list
 
Then update apt and install mosquitto - select "n" when it first explains the problem, then answer "Y" to the following proposal to use version **1.4.10** instead.:

    sudo apt-get update
    sudo aptitude install mosquitto

Then run this to see that mosquitto is listening on port 1883:

    netstat -plnt | grep 1883

# Arduino IDE
Arduinobot calls out to the binaries included in the Arduino IDE installation to perform it's work. Installing Arduino is easily done by simply downloading and unpacking:

    cd
    wget https://www.arduino.cc/download.php?f=/arduino-1.8.4-linuxarm.tar.xz
    mv *arduino*xz arduino-1.8.4-linuxarm.tar.xz
    tar xf arduino-1.8.4-linuxarm.tar.xz

# Arduinobot
Install git and other tools:

    sudo apt-get install git

If you wish to clone using git protocol, copy your keys to the Raspberry (using scp for example), then start the SSH agent and add key:

    eval "$(ssh-agent -s)"
    ssh-add ~/.ssh/id_rsa

...or whichever key you need to add. Then you should be able to clone out:

    git clone git@github.com:evothings/ecraft2learn.git

Otherwise, just use `http` instead:

    git clone https://github.com/evothings/ecraft2learn.git


## Installing Nim
Arduinobot is written in Nim, a modern high performance language that produces small and fast binaries by compiling via C. We first need to install Nim.

### Linux
For **regular Linux** (not Raspbian, see below!) you can install Nim the easiest using [choosenim](https://github.com/dom96/choosenim):

    curl https://nim-lang.org/choosenim/init.sh -sSf | sh

That will install the `nim` compiler and the `nimble` package manager.

### Raspbian
On Raspbian we need to install and bootstrap nim in a more manual fashion:

    wget https://nim-lang.org/download/nim-0.17.2.tar.xz
    tar xf nim-0.17.2.tar.xz 
    cd nim-0.17.2/
    sh build.sh
    bin/nim c koch
    ./koch tools

Finally we add this to ~/.profile

    export PATH=$PATH:~/nim-0.17.2/bin:~/.nimble/bin

Then we have the `nim` compiler and the `nimble` package manager available.

## Building Arduinobot
### Prerequisites
First we need to compile the [Paho C library](https://www.eclipse.org/paho/clients/c/) for communicating with MQTT. It's not available as far as I could tell via packages. This library is the de facto standard for MQTT communication and used in tons of projects.

To compile we also need libssl-dev:

    sudo apt-get install libssl-dev

Then we can build and install Paho C:

    git clone https://github.com/eclipse/paho.mqtt.c.git
    cd paho.mqtt.c
    make
    sudo make install
    sudo ldconfig

### Building
Now we are ready to build **arduinobot**. Enter the `arduinobot` directory and build it using the command `nimble build` or both build and install it using `nimble install`. This will download and install Nim dependencies automatically:

    cd ~/ecraft2learn/arduinobot
    nimble install

It should eventually end with:

    ...
    Installing arduinobot@0.1.0
    Building arduinobot/arduinobot using c backend
    Building arduinobot/arduinobotup using c backend
    Success: arduinobot installed successfully.

You can also run some tests, but they require a running MQTT server on localhost:

    nimble tests

### Adding service
Create `/etc/systemd/system/arduinobot.service`:

    [Unit]
    Description=Arduinobot
    After=network.target

    [Service]
    User=pi
    WorkingDirectory=/home/pi
    ExecStart=/home/pi/.nimble/bin/arduinobot -a /home/pi/arduino-1.8.4/arduino
    Restart=always
    RestartSec=60
        
    [Install]
    WantedBy=multi-user.target

Then enable it:

    systemctl daemon-reload
    systemctl enable arduinobot
    systemctl start arduinobot

## How to run
Arduinobot is a server and only needs an MQTT server to connect to in order to function. Use `--help` to see information on available options:

    gokr@yoda:~$ arduinobot --help
    arduinobot
    
    Usage:
        arduinobot [-u USERNAME] [-p PASSWORD] [-s MQTTURL]
        arduinobot (-h | --help)
        arduinobot (-v | --version)
    
    Options:
        -u USERNAME      Set MQTT username [default: test].
        -p PASSWORD      Set MQTT password [default: test].
        -s MQTTURL       Set URL for the MQTT server [default: tcp://localhost:1883]
        -h --help        Show this screen.
        -v --version     Show version.

In fact, with a running **mosquitto** locally using default configuration you should be able to run arduinobot without any arguments. It will then use default values for username, password and MQTT server.

If it works it should look something like this:

    gokr@yoda:~$ arduinobot 
    INFO Jester is making jokes at http://localhost:10000
    Cleaning out builds directory: /home/gokr/evo/ecraft2learn/arduinobot/src/builds
    Connecting as arduinobot-44bedc65-6e7b-4e33-b91e-dcba5fd4a6e0 to tcp://localhost:1883

Now you can test it out by using the included `arduinobotup` tool that can trivially submit a job to arduinobot. You can find `blinky.ino` in the tests directory so try it out with:

    arduinobotup --verify tests/blinky.ino

Or from another machine it should work using this:

    arduinobotup --server tcp://raspberrypi.local:1883 --verify tests/blinky.ino


## How to work on the code

* https://github.com/arduino/Arduino/blob/master/build/shared/manpage.adoc
* https://github.com/arduino/arduino-builder

I recommend installing [VSCode](https://code.visualstudio.com) and the [Nim extension](https://github.com/Microsoft/vscode-arduino) for it.

