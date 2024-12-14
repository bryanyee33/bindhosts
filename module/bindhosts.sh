#!/bin/sh
PATH=/data/adb/ap/bin:/data/adb/ksu/bin:/data/adb/magisk:$PATH:/data/data/com.termux/files/usr/bin
MODDIR="/data/adb/modules/bindhosts"
PERSISTENT_DIR="/data/adb/bindhosts"
. $MODDIR/mode.sh

# bindhosts.sh
# bindhosts' processing backend

nproc=$(busybox nproc)

# grab own info (version)
versionCode=$(grep versionCode $MODDIR/module.prop | sed 's/versionCode=//g' )

# test out writables, prefer tmpfs
folder=$MODDIR
[ -w /dev ] && folder=/dev
[ -w /sbin ] && folder=/sbin
[ -w /debug_ramdisk ] && folder=/debug_ramdisk


echo "[+] bindhosts v$versionCode"
echo "[%] bindhosts.sh"
echo "[%] standalone hosts-based-adblocking implementation"

[ -f $MODDIR/disable ] && {
	echo "[*] not running since module has been disabled"
	string="description=status: disabled ❌ | $(date)"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	return
}

# just in case user deletes them
# persistence
[ ! -d /data/adb/bindhosts ] && mkdir -p $PERSISTENT_DIR
files="custom.txt blacklist.txt sources.txt whitelist.txt"
for i in $files ; do
	if [ ! -f $PERSISTENT_DIR/$i ]; then
		# dont do anything weird, probably intentional
		echo "#" > $PERSISTENT_DIR/$i
	fi
done

adaway_warn() {
	pm path org.adaway > /dev/null 2>&1 && echo "[-] 🚨 Current operation mode may not work with AdAway 📛"
}

# impl def for changing variables
target_hostsfile="$MODDIR/system/etc/hosts"
helper_mode=""

# we can just remove the other unmodified modes
# and have them fall to * but im gonna leave it 
# here for clarity
case $operating_mode in
	0) if command -v ksud >/dev/null 2>&1 || command -v apd >/dev/null 2>&1 ; then adaway_warn ; fi ;;
	1) true ;;
	2) true ;;
	3) target_hostsfile="/data/adb/hosts" ; helper_mode="| hosts_file_redirect 💉" ; adaway_warn ;;
	4) target_hostsfile="/data/adb/hostsredirect/hosts" ; helper_mode="| ZN-hostsredirect 💉" ; adaway_warn ;;
	5) true ;;
	6) true ;;
	7) target_hostsfile="/system/etc/hosts" ;;
	8) target_hostsfile="/system/etc/hosts" ;;
	*) true ;; # catch invalid modes
esac

# check hosts file if writable, if not, warn and exit
if [ ! -w $target_hostsfile ] ; then
	# no fucking way
	echo "[x] unwritable hosts file 😭 needs correction 💢"
	string="description=status: unwritable hosts file 😭 needs correction 💢"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	return
fi

##### functions
illusion () {
	x=$(($$%4 + 4)); while [ $x -gt 1 ] ; do echo '[.]' ; sleep 0.1 ; x=$((x-1)) ; done &
}

enable_cron() {
	if [ ! -d $PERSISTENT_DIR/crontabs ]; then
		mkdir $PERSISTENT_DIR/crontabs
		echo "[+] running crond"
		busybox crond -bc $PERSISTENT_DIR/crontabs -L /dev/null
		echo "[+] adding crontab entry"
		echo "0 4 * * * sh /data/adb/modules/bindhosts/bindhosts.sh --force-update > /dev/null 2>&1 &" | busybox crontab -c $PERSISTENT_DIR/crontabs -
	else
		echo "[x] seems that it is already active, if you have issues fix it yourself"	
	fi
}

toggle_updatejson() {
	grep -q "^updateJson" $MODDIR/module.prop && { 
		sed -i 's/updateJson/xpdateJson/g' $MODDIR/module.prop 
		echo "[x] module updates disabled!" 
		} || { sed -i 's/xpdateJson/updateJson/g' $MODDIR/module.prop 
		echo "[+] module updates enabled!" 
		}
}

# probe for downloaders
# wget = low pref, no ssl.
# curl, has ssl on android, we use it if found
# here we chant the https meme.
# https doesn't hide the fact that i'm using https so that's why i don't use encryption 
# because everyone is trying to crack encryption so i just don't use encryption because 
# no one is looking at unencrypted data because everyone wants encrypted data to crack
download() {
	if command -v curl > /dev/null 2>&1; then
		curl --connect-timeout 10 -s "$1"
        else
		busybox wget -T 10 --no-check-certificate -qO - "$1"
        fi
}

sort_cmd() {
	if [ -f /data/data/com.termux/files/usr/bin/sort ]; then
		/data/data/com.termux/files/usr/bin/sort --parallel=$nproc -u
        else
		sort -u
        fi
}        


adblock() {
	# source processing start!
	echo "[+] processing sources"
	grep -v "#" $PERSISTENT_DIR/sources.txt | grep http > /dev/null || {
			echo "[x] no sources found 😭" 
			echo "[x] sources.txt needs correction 💢"
			return
			}
	illusion
        # download routine start!
	for url in $(grep -v "#" $PERSISTENT_DIR/sources.txt | grep http) ; do 
		echo "[+] grabbing.."
		echo "[>] $url"
		download "$url" >> $folder/temphosts || echo "[x] failed downloading $url"
	done
	# if temphosts is empty
	# its either user did something
	# or inaccessible urls / no internet
	[ ! -s $folder/temphosts ] && {
		echo "[!] downloaded hosts found to be empty"
		echo "[!] using old hosts file!"
		# strip first two lines since thats just localhost
		tail -n +3 $target_hostsfile > $folder/temphosts
		}
	# localhost
	printf "127.0.0.1 localhost\n::1 localhost\n" > $target_hostsfile
	# always restore user's custom rules
	grep -v "#" $PERSISTENT_DIR/custom.txt >> $target_hostsfile
	# blacklist.txt
	for i in $(grep -v "#" $PERSISTENT_DIR/blacklist.txt ); do echo "0.0.0.0 $i" >> $folder/temphosts; done
	# whitelist.txt
	echo "[+] processing whitelist"
	# make sure tempwhitelist isnt empty
	# or it will grep out nothingness from everything
	# which actually greps out everything.
	echo "256.256.256.256 bindhosts" > $folder/tempwhitelist
	for i in $(grep -v "#" $PERSISTENT_DIR/whitelist.txt); do echo "0.0.0.0 $i" ; done >> $folder/tempwhitelist
	# sed strip out everything with #, double space to single space, replace all 127.0.0.1 to 0.0.0.0
	# then sort uniq, then grep out whitelist.txt from it
	sed '/#/d; s/  / /g; /^$/d; s/127.0.0.1/0.0.0.0/' $folder/temphosts | sort_cmd | grep -Fxvf $folder/tempwhitelist | busybox dos2unix >> $target_hostsfile
	# mark it, will be read by service.sh to deduce
	echo "# bindhosts v$versionCode" >> $target_hostsfile
}

reset() {
	echo "[+] reset toggled!" 
	# localhost
	printf "127.0.0.1 localhost\n::1 localhost\n" > $target_hostsfile
	# always restore user's custom rules
	grep -v "#" $PERSISTENT_DIR/custom.txt >> $target_hostsfile
        string="description=status: reset 🤐 | $(date)"
        sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
        illusion
        sleep 1
        echo "[+] hosts file reset!"
        # reset state
        rm $PERSISTENT_DIR/bindhosts_state > /dev/null 2>&1
        sleep 1
}

run() {
	adblock
	illusion
	sleep 1
	# store these as variables
	# this way we dont do the grepping twice
	custom=$( grep -vEc "0.0.0.0| localhost|#" $target_hostsfile)
	blocked=$(grep -c "0.0.0.0" $target_hostsfile )
	# now use them
	echo "[+] blocked: $blocked | custom: $custom "
	string="description=status: active ✅ | blocked: $blocked 🚫 | custom: $custom 🤖 $helper_mode"
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	# ready for reset again
	(cd $PERSISTENT_DIR ; (cat blacklist.txt custom.txt sources.txt whitelist.txt ; date +%F) | busybox crc32 > $PERSISTENT_DIR/bindhosts_state )
	# cleanup
	rm -f $folder/temphosts $folder/tempwhitelist
	sleep 1
}

# adaway is installed and hosts are modified by adaway, dont overthrow
pm path org.adaway > /dev/null 2>&1 && grep -q "generated by AdAway" /system/etc/hosts && {
	# adaway coex
	string="description=status: active ✅ | 🛑 AdAway 🕊️"
	sed -i "s/^description=.*/$string/g" $MODDIR/module.prop
	echo "[*] 🚨 hosts modified by Adaway 🛑"
	echo "[*] assuming coexistence operation"
	echo "[*] please reset hosts in Adaway before continuing"
	return
}

# add arguments
case "$1" in 
	--force-update) run; exit ;;
	--force-reset) reset; exit ;;
	--enable-cron) enable_cron; exit ;;
	--toggle-updatejson) toggle_updatejson; exit ;;
esac

# single instance lock
# as the script sometimes takes some time processing
# we implement a simple lockfile logic around here to
# prevent multiple instances.
# warn and dont run if lockfile exists
[ -f $folder/bindhosts_lockfile ] && {
	echo "[*] already running!"
	# keep exit 0 here since this is a single instance lock
	exit 0
	}
# if lockfile isnt there, we create one
[ ! -f $folder/bindhosts_lockfile ] && touch $folder/bindhosts_lockfile

# toggle start!
if [ -f $PERSISTENT_DIR/bindhosts_state ]; then
	# handle rule changes, add date change detect, I guess a change of 1 day to update is sane.
	newhash=$(cd $PERSISTENT_DIR ; (cat blacklist.txt custom.txt sources.txt whitelist.txt ; date +%F) | busybox crc32 )
	oldhash=$(cat $PERSISTENT_DIR/bindhosts_state)
	if [ $newhash = $oldhash ]; then
		# well if theres no rule change, user just wants to disable adblocking
		reset
	else
		echo "[+] rule change detected!"
		echo "[*] new: $newhash"
		echo "[*] old: $oldhash"
		run
	fi
else
	# basically if no bindhosts_state and hosts file is marked just update, its a reinstall
	grep -q "# bindhosts v" $target_hostsfile && echo "[+] update triggered!"
	# normal flow
	run
fi

# cleanup lockfile
[ -f $folder/bindhosts_lockfile ] && rm $folder/bindhosts_lockfile > /dev/null 2>&1

# EOF
