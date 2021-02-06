#!/bin/bash
##START getBlackListHosts
#   This script gets various anti-ad hosts files, merges, sorts, and uniques, then installs.
#   Run from cron once a week.
#   This script adds the hosts to the dnsmasq via /etc/dnsmasq.d by way of 10000 line files
#
#   This script is modified version of / based on buildhosts by:
#   Matthew Headlee <mmh@matthewheadlee.com> (http://matthewheadlee.com/).
#
#   This file is getBlacklistHosts
#
#   getBlacklistHosts is free software: you can redistribute
#   it and/or modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 3 of the License,
#   or (at your option) any later version.
#
#   getBlacklistHosts is distributed in the hope that it will
#   be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General
#   Public License for more details.
#
#   You should have received a copy of the GNU General Public License along with
#   buildhosts.  If not, see
#   <http://www.gnu.org/licenses/>.
#exit 1


## the user configurable options are now located in getBlacklistHosts.conf
## which is created in the same directory this script is in, on first run of this script.
## If it does not exist, run this script to create it, then edit it (if desired).

#Version of this script
version="V8.7"

#full path and filename to file which holds the count of hosts from the previous run - depreciated
#this file will be imported into the .conf file and deleted if it exists
oldcountFile="/config/scripts/getBlacklistHosts.oldcount"

#full path and filename to file which holds the count of hosts from the current run - depreciated
#this file will be imported into the .conf file and deleted if it exists
currentcountFile="/config/scripts/getBlacklistHosts.currentcount"

#name to use for the options file that will be generated in dnsmasqHome if options found in conf file
#variable dnsmasqOptions
optionsFileName="getBlacklistOptions.conf"

#get the scripts current home
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
scriptHome="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

#filename of file which holds the various conf elements, this needs to exist in the same directory this script is running in
dataFile="${scriptHome}/getBlacklistHosts.conf"

#temp file to hold mail message (deleted by script after use)
messageFile="$(mktemp "/tmp/tmp.BlacklistMessage.txt.XXXXXX")"

#temp file to hold mail header (deleted by script after use)
messageHeader="$(mktemp "/tmp/tmp.BlacklistHeader.txt.XXXXXX")"

#temp file to hold mail footer (deleted by script after use)
messageFooter="$(mktemp "/tmp/tmp.BlacklistFooter.txt.XXXXXX")"

#location of log file. This file gets reset with each run of this script

if [ "${scriptHome}" != "/config/scripts" ]; then
	#not the default home, append folder name
	folder=$(basename ${scriptHome});
	readonly logFile="/var/log/getBlackListHosts.$folder.log"
	
else
	#default home, use default log
	readonly logFile="/var/log/getBlackListHosts.log"
fi


echo $(date) > ${logFile}
startTime=`date +%s`

declare -i iBlackListCount=0


function cleanup() {
    #Removes temporary files created during this scripts execution.
    echo ".    Purging temporary files..." | sendmsg
    rm -f "${sTmpNewHosts}" "${sTmpAdHosts}" "${sTmpShallaMD5}" "${sTmpDomainss}" "${sTmpSubFilters}" "${sTmpCleaneds}" "${sTmpWhiteDomains}" "${sTmpDomains2s}" "${sTmpWhiteHosts}" "${sTmpWhiteNoneWild}" "${sTmpWhiteNonSub}" "${sTmpCurlDown}"
}

function cleanupOthers() {
    #Removes other temporary files created during this scripts execution.
    rm -f "${messageFile}" "${messageHeader}" "${messageFooter}"
	rm -rf ${sTmpExtracts}
	rm -rf ${sTmpHostSplitterD}
	rm -rf ${sTmpCurlUnzip}
}

function control_c() {
    echo -e "Script canceled."
    cleanup
	cleanupOthers
    exit 4
}

sendmsg()
{
	read IN
	if [ -t 1 ]; then
	    echo -e "$IN"
		echo -e "$IN" >> ${logFile}
		
	else
	    echo -e "$IN" >> ${logFile}
	fi
}
echo " " | sendmsg
echo ".    Starting getBlackListHosts ${version}..." | sendmsg

#Used for cleanup on ctrl-c / ensure this script exit cleanly.
trap 'control_c' HUP INT QUIT TERM

#Sanity check to ensure all script dependencies are met.
for cmd in cat curl date mktemp pkill rm sed sort uniq grep; do
    if ! type "${cmd}" &> /dev/null; then
        bError=true
        echo "This script requires the command '${cmd}' to run. Install '${cmd}', make it available in \$PATH and try again." | sendmsg
    fi
done
${bError:-false} && exit 1

stringGrepText=$(grep --version 2>&1)

if [[ $stringGrepText = *"BusyBox"* ]]; then
  echo "WARNING - BusyBox Grep detected. This script may take several hours to run, please install GNU Grep for a better experience!" | sendmsg
fi



#Temporary files to hold the new hosts and cleaned up hosts
readonly sTmpNewHosts="$(mktemp "/tmp/tmp.newhosts.XXXXXX")"
readonly sTmpAdHosts="$(mktemp "/tmp/tmp.adhosts.XXXXXX")"
readonly sTmpDomainss="$(mktemp "/tmp/tmp.addomains.XXXXXX")"
readonly sTmpSubFilters="$(mktemp "/tmp/tmp.subFilters.XXXXXX")"
readonly sTmpDomains2s="$(mktemp "/tmp/tmp.addomains2.XXXXXX")"
readonly sTmpCleaneds="$(mktemp "/tmp/tmp.cleaned.XXXXXX")"
readonly sTmpWhiteDomains="$(mktemp "/tmp/tmp.whiteDomains.XXXXXX")"
readonly sTmpWhiteHosts="$(mktemp "/tmp/tmp.whiteHosts.XXXXXX")"
readonly sTmpWhiteNoneWild="$(mktemp "/tmp/tmp.whiteNonWild.XXXXXX")"
readonly sTmpExtracts="$(mktemp -d "/tmp/tmp.hostExtract.XXXXXX")"
readonly sTmpHostSplitterD="$(mktemp -d "/tmp/tmp.hostsplitter.XXXXXX")"
readonly sTmpWhiteNonSub="$(mktemp "/tmp/tmp.whiteNonWild.XXXXXX")"
readonly sTmpCurlDown="$(mktemp "/tmp/tmp.CurlDown.XXXXXX")"
readonly sTmpCurlUnzip="$(mktemp -d "/tmp/tmp.CurlUnzip.XXXXXX")"


#these are common across instances, do not randomize names
#this holds downloaded shalla data file - we keep this between runs
readonly sTmpGzips="/tmp/tmp.gzippedhosts.tar.gz"
readonly sTmpShallaMD5="/tmp/shallaMD5"

if [ ! -w "${messageFile}" ]; then
    echo "Failed to create temporary file messageFile " | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${messageHeader}" ]; then
    echo "Failed to create temporary file messageHeader " | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${messageFooter}" ]; then
    echo "Failed to create temporary file messageFooter " | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpNewHosts}" ]; then
    echo "Failed to create temporary file sTmpNewHosts " | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpAdHosts}" ]; then
    echo "Failed to create temporary file sTmpAdHosts" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpDomainss}" ]; then
    echo "Failed to create temporary file sTmpDomainss" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpSubFilters}" ]; then
    echo "Failed to create temporary file sTmpSubFilters" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi


if [ ! -w "${sTmpDomains2s}" ]; then
    echo "Failed to create temporary file sTmpDomains2s" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpCleaneds}" ]; then
    echo "Failed to create temporary file sTmpCleaneds" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpWhiteDomains}" ]; then
    echo "Failed to create temporary file sTmpWhiteDomains" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpWhiteHosts}" ]; then
    echo "Failed to create temporary file sTmpWhiteHosts" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpWhiteNoneWild}" ]; then
    echo "Failed to create temporary file sTmpWhiteNoneWild" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpWhiteNonSub}" ]; then
    echo "Failed to create temporary file sTmpWhiteNonSub" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpCurlDown}" ]; then
    echo "Failed to create temporary file sTmpCurlDown" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpCurlUnzip}" ]; then
    echo "Failed to create temporary directory sTmpCurlUnzip" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpExtracts}" ]; then
    echo "Failed to create temporary directory sTmpExtracts" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

if [ ! -w "${sTmpHostSplitterD}" ]; then
    echo "Failed to create temporary directory sTmpHostSplitterD" | sendmsg
    echo "This probably means the filesystem is full or read-only." | sendmsg
    cleanup
	cleanupOthers
    exit 2
fi

#create default conf file if it does not exist
#################################################
if [ ! -f ${dataFile} ]; then
echo -e "#This is the user configuration file for ${scriptHome}/getBlacklistHosts.sh ${version}\n\
\n\
\n\
#location of the whitelist. This file contains one host/domain per line that will\n\
#be excluded from the blacklist. If the file does not exist it wll not be used.\n\
\n\
readonly whitelist=\"${scriptHome}/dnswhitelist\"\n\
\n\
#Examples below show the whitelist results on these blacklist entries:\n\
#somedomain.com\n\
#api.somedomain.com\n\
#cdn.somedomain.com\n\
#events.somedomain.com\n\
\n\
#no dnswhitelist entry:\n\
#entire somedomain.com is blocked due to 'somedomain.com' being included in the blacklist data\n\
\n\
#dnswhitelist entry: *somedomain.com (note no dot between * and domain name)\n\
#resulting blacklist entries:\n\
#none - entire domain whitelisted\n\
\n\
#dnswhitelist entry: somedomain.com\n\
#resulting blacklist entries:\n\
#address=/api.somedomain.com/0.0.0.0\n\
#address=/cdn.somedomain.com/0.0.0.0\n\
#address=/events.somedomain.com/0.0.0.0\n\

#dnswhitelist entry: api.somedomain.com - this one subdomain will be whitelisted\n\
#resulting blacklist entries:\n\
#address=/somedomain.com/0.0.0.0\n\
#address=/cdn.somedomain.com/0.0.0.0\n\
#address=/events.somedomain.com/0.0.0.0\n\
\n\
\n\
\n\
\n\
#location of the user-defined blacklist. This file contains one host/domain per line that will\n\
#be included in the final blacklist. If the file does not exist it will not be used.\n\
#If a domain is listed the entire domain and all subdomains will be blocked.\n\
#If a subdomain or specific host is listed, only that will be blocked.\n\
#This does not use the * to denote a domain as the whitelist does.\n\
readonly userblacklist=\"${scriptHome}/dnsblacklist\"\n\
\n\
\n\
\n\
\n\
#user-defined source URLs\n\
#you can add your own source URLs here from which the script will download\n\
#additional blacklist entries. You can have as may as you like.\n\
#If no URLs are defined it will be skipped during processing.\n\
#This URL can be a zip file containing one or more files.\n\
\n\
#user-defined source URL format is:\n\
#URLarray[uniqueLabel]=\"sourceUrl\"\n\
#where uniqueLabel is a unique (per URL) character string with no spaces or extended characters and\n\
#sourceUrl is the URL to pull from.\n\
\n\
#example:\n\
#URLarray[site1]=\"http://TestMyLocalUSGDns.com/badhosts\"\n\
#URLarray[site2]=\"https://TestMyLocalUSGDns2.com/morebadhosts\"\n\
\n\
\n\
\n\
\n\
#script-provided source URLs\n\
#These are the source URLs that come with this script.\n\
#The first entries are the pi-hole sources listed at\n\
#https://github.com/pi-hole/pi-hole/blob/master/adlists.default\n\
#If you want to run exactly the same sources as pi-hole, comment out\n\
#the other sources in this section.\n\
#If you do not want to use any of these sources you may comment them all out.\n\
#As a note, please do not remove or add lines from this section.\n\
#To remove sources simply comment out the line with a leading #.\n\
#To add sources please add them to the user-defined section above.\n\
#This is to ensure that if future updates contain more sources they can be added\n\
#via the script during the update process and not confict with any user made changes.\n\
\n\
#Pi-hole source 1: StevenBlack list\n\
ProvidedURLarray[pi1]=\"https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts\"\n\
\n\
#Pi-hole source 2: MalwareDomains\n\
ProvidedURLarray[pi2]=\"http://malware-domains.com/files/justdomains.zip\"\n\
\n\
#Pi-hole source 3: Cameleon\n\
ProvidedURLarray[pi3]=\"http://sysctl.org/cameleon/hosts\"\n\
\n\
#Pi-hole source 4: Zeustracker\n\
ProvidedURLarray[pi4]=\"https://zeustracker.abuse.ch/blocklist.php?download=domainblocklist\"\n\
\n\
#Pi-hole source 5: Disconnect.me Tracking\n\
ProvidedURLarray[pi5]=\"https://s3.amazonaws.com/lists.disconnect.me/simple_tracking.txt\"\n\
\n\
#Pi-hole source 6: Disconnect.me Ads\n\
ProvidedURLarray[pi6]=\"https://s3.amazonaws.com/lists.disconnect.me/simple_ad.txt\"\n\
\n\
#Pi-hole source 7: Hosts-file.net\n\
ProvidedURLarray[pi7]=\"https://raw.githubusercontent.com/evankrob/hosts-filenetrehost/master/ad_servers.txt\"\n\
\n\
#Other source 1\n\
ProvidedURLarray[O1]=\"http://winhelp2002.mvps.org/hosts.txt\"\n\
\n\
#Other source 2\n\
ProvidedURLarray[O2]=\"https://adaway.org/hosts.txt\"\n\
\n\
#Other source 3\n\
ProvidedURLarray[O3]=\"https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&mimetype=plaintext\"\n\
\n\
#Other source 4\n\
ProvidedURLarray[O4]=\"https://someonewhocares.org/hosts/hosts/\"\n\
\n\
\n\
\n\
\n\
#Shalla sources:\n\
#Sources from the blacklist to use. See http://www.shallalist.de/categories.html for categories.\n\
#You can add or comment out categories from this area.\n\
#If no categories are defined it will be skipped during processing.\n\
\n\
#Shalla list category format is:\n\
#ShallaArray[uniqueLabel]=\"ShallaCategory\"\n\
#where uniqueLabel is a unique (per category) character string with no spaces or extended characters and\n\
#ShallaCategory is an exact Shalla category from http://www.shallalist.de/categories.html.\n\
\n\
#Shalla advertising:\n\
ShallaArray[Shalla1]=\"adv\"\n\
\n\
#Shalla spyware:\n\
ShallaArray[Shalla2]=\"spyware\"\n\
\n\
#Shalla tracker:\n\
ShallaArray[Shalla3]=\"tracker\"\n\
\n\
\n\
\n\
\n\
#What is the time limit (in seconds) for each file download?\n\
#This is to set a limit for curl when downloading from each source.\n\
#Without a limit curl would wait forever for a file to finish.\n\
#This sets the --max-time parameter for curl.\n\
#If you have a slower connection, you may need to increase the default 60 seconds.\n\
curlMaxTime=\"60\"\n\
\n\
\n\
\n\
\n\
#What IP address do you want the blocked hosts to resolve to?\n\
#0.0.0.0 is the default setting.\n\
#This has to be a valid IP address, not URL or hostname.\n\
#For more information on why the default is not 127.0.0.1, see here:\n\
#https://github.com/StevenBlack/hosts#we-recommend-using-0000-instead-of-127001\n\
resolveAddress=\"0.0.0.0\"\n\
\n\
\n\
\n\
\n\
#Where do you want to put the dnsmasq config files this script makes?\n\
#/etc/dnsmasq.d is the default setting.\n\
#This would only need to be changed if you are configuring this script to update\n\
#a secondary instance of dnsmasq.\n\
#Do not put a trailing slash here.\n\
dnsmasqHome=\"/etc/dnsmasq.d\"\n\
\n\
\n\
\n\
\n\
#What is the name of the dnsmasq instance in /etc/init.d/ that we are going to restart?\n\
#dnsmasq is the default setting.\n\
#This would only need to be changed if you are configuring this script to update\n\
#a secondary instance of dnsmasq and you have the init.d file named something else.\n\
#We are going to call \"/etc/init.d/<this filename here> force-reload\" using this name.\n\
dnsmasqName=\"dnsmasq\"\n\
\n\
\n\
\n\
\n\
#Are there any options that you want to pass to dnsmasq?\n\
#Dnsmasq options can be found at http://www.thekelleys.org.uk/dnsmasq/docs/dnsmasq-man.html.\n\
#Any options put here will be provided to dnsmasq in a .conf file located in the home folder specified above.\n\
#The options will be read by dnsmasq when this script restarts it after processing.\n\
#This is a ; delmited list, not not include the leading -- just the options themselves.\n\
#If you do not want to specify any options, keep this empty.\n\
#If you do want to specify any options, place them between the \" marks.\n\
#An example is: \"log-queries;some-other-option\"\n\
#The above example would enable dnsmasq logging of each query, and also some-other-option as well.\n\
dnsmasqOptions=\"\"\n\
\n\
\n\
\n\
\n\
#debugging\n\
#do you want to save a copy of these files for debugging:\n\
#nonFilteredHosts - contains raw dump of all the downloaded and user-defined hosts\n\
#singleDomains - list of all single domains from which all sub-domains will be removed in the final list\n\
#filteredHosts - contains the cleaned list before whitelist processing\n\
#finalHosts - final file after whitelist procesing that dnsmasq entries are created from\n\
#these files will be saved in ${scriptHome} by default.\n\
#true/false\n\
enableDebugging=false\n\
\n\
#change the default debugging output directory by changing the next line\n\
#this directory must exist. Do not put a trailing slash\n\
debugDirectory=${scriptHome}\n\
\n\
\n\
\n\
\n\
#do you want to stop the script before dnsmasq files are created?\n\
#false (default setting) - script runs and configures dnsmasq\n\
#true - script will process downloads then stop. It will not create dnsmasq configuration.\n\
#This will let you test your file downloads and generate (if you configure them) debug files.\n\
stopBeforeConfig=false\n\
\n\
\n\
\n\
\n\
#filename that will be run after the script finishes. If it does not exist it will not be run.\n\
postRun=\"${scriptHome}/getBlacklistPostRun.sh\"\n\
\n\
\n\
\n\
\n\
#do you want to receive an email when script is run? true/false\n\
#note this host must be setup to send mail via /usr/bin/ssmtp\n\
#see revaliases and ssmtp.conf in /etc/ssmtp\n\
sendEmails=false\n\
\n\
#email address (user@domain.com) to send mail to\n\
emailtoaddr=\"youremail@somedomain.com\"\n\
\n\
#mail from name to use \n\
emailfromname=\"USG Main Router\"\n\
\n\
#email address (user@domain.com) to send mail from\n\
#note this address must be setup to send mail via /usr/bin/ssmtp\n\
#see revaliases and ssmtp.conf in /etc/ssmtp\n\
emailfromaddr=\"youremail@somedomain.com\"\n\
\n\
#email subject to use\n\
emailsubject=\"USG hostblacklist updated\"\n\
\n\
\n\
\n\
\n\
#do you want to create a comma delimited history count when script is run? true/false\n\
recordHistory=false\n\
\n\
#full path and filename to file which holds the comma delmited hosts count history\n\
#this is ignored if recordHistory is set to false above\n\
historycountFile=\"${scriptHome}/BlacklistHistoryCount.txt\"\n\
\n\
\n\
\n\
\n\
#Shall the dnsmasq addn-hosts directive be used?\n\
#There are two ways providing url host entries.\n\
#1) legacy mode: \"address=/url.tld/0.0.0.0\"\n\
#2) addn-hosts: \"0.0.0.0 url.tld\"\n\
#addn-hosts is faster\n\
#https://www.reddit.com/r/sysadmin/comments/beqbcj/dnsmasq_is_very_slow_due_to_adblocking/\n\
useAddnHosts=true\n\
\n\
\n\
\n\
\n\
################################\n\
#data from reoccuring runs is below, do not edit\n"> ${dataFile}

#convert old format count files to new format if they exist
if [ -f ${currentcountFile} ]; then
	echo ".    Converting old format current count file..." | sendmsg
	convert_current=$(cat $currentcountFile)
	rm ${currentcountFile}
else 
	convert_current="0"
fi
	if [ -f ${oldcountFile} ]; then
	echo ".    Converting old format old count file..." | sendmsg
	convert_old=$(cat $oldcountFile)
	rm ${oldcountFile}
else
	convert_old="0"
fi

echo -e "current_count=\"$convert_current\"" >> ${dataFile}
echo -e "old_count=\"$convert_old\"" >> ${dataFile}
echo -e "current_shallaMD5=\"none\"" >> ${dataFile}

cleanup
cleanupOthers

echo " " | sendmsg
echo ".    Created default data file which did not exist, the Blacklist Hosts have NOT been updated." | sendmsg
echo ".    Next time the script runs the Blacklist Hosts will be updated." | sendmsg
echo ".    This is so you can adjust settings in ${dataFile} before the first updates." | sendmsg
echo ".    Once you have made changes (or not if you want the defaults), run this script again." | sendmsg
echo " " | sendmsg
exit
fi
#End create conf file if it does not exist
####################################################


somethingAdded=false

#conf file updates

#add version to first line
if ! grep -q "${scriptHome}/getBlacklistHosts.sh ${version}" ${dataFile}; then
  echo ".    Updating to ${version} in conf file..." | sendmsg
  homeSed=$(echo "$scriptHome" | sed 's/\//\\\//g');
  sed -i "/${homeSed}\/getBlacklistHosts.sh/c\#This is the user configuration file for ${scriptHome}/getBlacklistHosts.sh ${version}" ${dataFile}
  if grep -q "the user configuration file for getBlacklistHosts.sh" ${dataFile}; then
    sed -i "/the user configuration file for getBlacklistHosts.sh/c\#This is the user configuration file for ${scriptHome}/getBlacklistHosts.sh ${version}" ${dataFile}
  fi
  echo ".    Removing '***NEW OPTION***' from old options..." | sendmsg
  sed -i '/NEW OPTION/d' ${dataFile}
  somethingAdded=true
fi
#end add version to first line


#add the userblacklist area
if ! grep -q "userblacklist" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#location of the user-defined blacklist. This file contains one host/domain per line that will\
#be included in the final blacklist. If the file does not exist it will not be used.\
#If a domain is listed the entire domain and all subdomains will be blocked.\
#If a subdomain or specific host is listed, only that will be blocked.\
readonly userblacklist="'"${scriptHome}"'/dnsblacklist"\
' ${dataFile}
  echo ".    Adding userblacklist to conf file..." | sendmsg
  somethingAdded=true
fi
#end user blacklist area


#text update to userblacklist area
sed -i "/#This works the same as the whitelist above. If a domain is listed the entire domain/\
c\#If a domain is listed the entire domain and all subdomains will be blocked." ${dataFile}
sed -i "/#and all subdomains will be blocked. If a subdomain or specific host is listed, only that will be blocked./\
c\#If a subdomain or specific host is listed, only that will be blocked." ${dataFile}

if ! grep -q "This does not use the \* to denote a domain as the whitelist does." ${dataFile}; then
  sed -i "/#If a subdomain or specific host is listed, only that will be blocked./\
a #This does not use the * to denote a domain as the whitelist does." ${dataFile}
fi

#end text update to userblacklist


#text update to whitelist area
sed -i "/#be excluded from the blacklist based on a partial match. If the file does not exist/\
c\#be excluded from the blacklist. If the file does not exist it will not be used." ${dataFile}
sed -i '/#it will not be used./d' ${dataFile}

sed -i "/#Examples:/\
c\#Examples below show the whitelist results on these blacklist entries:" ${dataFile}

sed -i "/#somedomain.com - will remove all entries including subdomains, so it will remove:/\
c\#somedomain.com\n\
#api.somedomain.com" ${dataFile}

sed -i "/#somedomain.com, sub1.somedomain.com, sub2.somedomain.com, etc./\
c\#cdn.somedomain.com\n\
#events.somedomain.com" ${dataFile}

sed -i "/#sub1.somedomain.com would only remove sub1.somedomain.com, keeping:/\
c\#no dnswhitelist entry:\n\
#entire somedomain.com is blocked due to 'somedomain.com' being included in the blacklist data\n\
\n\
#dnswhitelist entry: *somedomain.com (note no dot between * and domain name)\n\
#resulting blacklist entries:\n\
#none - entire domain whitelisted\n\
\n\
#dnswhitelist entry: somedomain.com\n\
#resulting blacklist entries:\n\
#address=\/api.somedomain.com\/0.0.0.0\n\
#address=\/cdn.somedomain.com\/0.0.0.0\n\
#address=\/events.somedomain.com\/0.0.0.0\n\
\n\
#dnswhitelist entry: api.somedomain.com\n\
#resulting blacklist entries:\n\
#address=\/cdn.somedomain.com\/0.0.0.0\n\
#address=\/events.somedomain.com\/0.0.0.0" ${dataFile}

sed -i 's/#somedomain.com and sub2.somedomain.com in the blacklist./\n/g' ${dataFile}

sed -i "/#dnswhitelist entry: api.somedomain.com/,\
/#address=\/cdn.somedomain.com\/0.0.0.0/\
c\#dnswhitelist entry: api.somedomain.com - this one subdomain will be whitelisted\n\
#resulting blacklist entries:\n#address=/somedomain.com/0.0.0.0\n#address=/cdn.somedomain.com/0.0.0.0" ${dataFile}

#end text update to whitelist area


#add the user defined URL area
if ! grep -q "URLarray" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#user-defined source URLs\
#you can add your own source URLs here from which the script will download\
#additional blacklist entries. You can have as may as you like.\
#If no URLs are defined it will be skipped during processing.\
\
#user-defined source URL format is:\
#URLarray[uniqueLabel]="sourceUrl"\
#where uniqueLabel is a unique (per URL) character string with no spaces or extended characters and\
#sourceUrl is the URL to pull from.\
\
#example:\
#URLarray[site1]="http://TestMyLocalUSGDns.com/badhosts"\
#URLarray[site2]="https://TestMyLocalUSGDns2.com/morebadhosts"\
' ${dataFile}
  echo ".    Adding URLarray to conf file..." | sendmsg
  somethingAdded=true
fi
#end user definded URL area


#add debugging area
if ! grep -q "enableDebugging" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#debugging\
#do you want to save a copy of these three files for debugging:\
#nonFilteredHosts - contains raw dump of all the downloaded and user-defined hosts\
#singleDomains - list of all single domains from which all sub-domains will be removed in the final list\
#filteredHosts - contains the cleaned list before whitelist processing\
#finalHosts - final file after whitelist procesing that dnsmasq entries are created from\
#these files will be saved in '"${scriptHome}"' by default\
#true/false\
enableDebugging=false\
\
#change the default debugging output directory by changing the next line\
#this directory must exist. Do not put a trailing slash\
debugDirectory='"${scriptHome}"'\
' ${dataFile}
  echo ".    Adding enableDebugging to conf file..." | sendmsg
  somethingAdded=true
fi
#end debugging area


#add debugging singleDomains info area
if ! grep -q "singleDomains" ${dataFile}; then
  sed -i '/#filteredHosts - contains the cleaned list before whitelist processing/ i \
#singleDomains - list of all single domains from which all sub-domains will be removed in the final list\' ${dataFile}

sed -i '/#debugging/ i \
#***NEW OPTION***' ${dataFile}

  echo ".    Adding debugging singleDomains info to conf file..." | sendmsg
  somethingAdded=true
fi
#end debugging singleDomains info area



#add script-provided sources area
if ! grep -q "ProvidedURLarray" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#script-provided source URLs\
#These are the source URLs that come with this script.\
#The first entries are the pi-hole sources listed at\
#https:\/\/github.com\/pi-hole\/pi-hole\/blob\/master\/adlists.default\
#If you want to run exactly the same sources as pi-hole, comment out\
#the other sources in this section.\
#If you do not want to use any of these sources you may comment them all out.\
#As a note, please do not remove or add lines from this section.\
#To remove sources simply comment out the line with a leading #.\
#To add sources please add them to the user-defined section above.\
#This is to ensure that if future updates contain more sources they can be added\
#via the script during the update process and not confict with any user made changes.\
\
#Pi-hole source 1: StevenBlack list\
ProvidedURLarray\[pi1]=\"https:\/\/raw.githubusercontent.com\/StevenBlack\/hosts\/master\/hosts\"\
\
#Pi-hole source 2: MalwareDomains\
ProvidedURLarray\[pi2]=\"https:\/\/mirror1.malwaredomains.com\/files\/justdomains\"\
\
#Pi-hole source 3: Cameleon\
ProvidedURLarray\[pi3]=\"http:\/\/sysctl.org\/cameleon\/hosts\"\
\
#Pi-hole source 4: Zeustracker\
ProvidedURLarray\[pi4]=\"https:\/\/zeustracker.abuse.ch\/blocklist.php?download=domainblocklist\"\
\
#Pi-hole source 5: Disconnect.me Tracking\
ProvidedURLarray\[pi5]=\"https:\/\/s3.amazonaws.com\/lists.disconnect.me\/simple_tracking.txt\"\
\
#Pi-hole source 6: Disconnect.me Ads\
ProvidedURLarray\[pi6]=\"https:\/\/s3.amazonaws.com\/lists.disconnect.me\/simple_ad.txt\"\
\
#Pi-hole source 7: Hosts-file.net\
ProvidedURLarray\[pi7]=\"https:\/\/hosts-file.net\/ad_servers.txt\"\
\
#Other source 1\
ProvidedURLarray\[O1]=\"http:\/\/winhelp2002.mvps.org\/hosts.txt\"\
\
#Other source 2\
ProvidedURLarray\[O2]=\"https:\/\/adaway.org\/hosts.txt\"\
\
#Other source 3\
ProvidedURLarray\[O3]=\"https:\/\/pgl.yoyo.org\/adservers\/serverlist.php?hostformat=hosts&mimetype=plaintext\"\
\
#Other source 4\
ProvidedURLarray\[O4]=\"https:\/\/someonewhocares.org\/hosts\/hosts\/\"\
' ${dataFile}
  echo ".    Adding ProvidedURLarray to conf file..." | sendmsg
  somethingAdded=true
fi
#end script-provided sources area


#add shalla list area
if ! grep -q "ShallaArray" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#Shalla sources:\
#Sources from the blacklist to use. See http:\/\/www.shallalist.de\/categories.html for categories.\
#You can add or comment out categories from this area.\
#If no categories are defined it will be skipped during processing.\
\
#Shalla list category format is:\
#ShallaArray\[uniqueLabel]=\"ShallaCategory\"\
#where uniqueLabel is a unique (per category) character string with no spaces or extended characters and\
#ShallaCategory is an exact Shalla category from http:\/\/www.shallalist.de\/categories.html.\
\
#Shalla advertising:\
ShallaArray\[Shalla1]=\"adv\"\
\
#Shalla spyware:\
ShallaArray\[Shalla2]=\"spyware\"\
\
#Shalla tracker:\
ShallaArray\[Shalla3]=\"tracker\"\
' ${dataFile}
  echo ".    Adding ShallaArray to conf file..." | sendmsg
  somethingAdded=true
fi
#end shalla list sources area


#add stopBeforeConfig area
if ! grep -q "stopBeforeConfig" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#do you want to stop the script before dnsmasq files are created?\
#false (default setting) - script runs and configures dnsmasq\
#true - script will process downloads then stop. It will not create dnsmasq configuration.\
#This will let you test your file downloads and generate (if you configure them) debug files.\
stopBeforeConfig=false\
' ${dataFile}
  echo ".    Adding stopBeforeConfig to conf file..." | sendmsg
  somethingAdded=true
fi

#end stopBeforeConfig area


#add resolveAddress area
if ! grep -q "resolveAddress" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#What IP address do you want the blocked hosts to resolve to?\
#0.0.0.0 is the default setting.\
#This has to be a valid IP address, not URL or hostname.\
#For more information on why the default is not 127.0.0.1, see here:\
#https:\/\/github.com\/StevenBlack\/hosts#we-recommend-using-0000-instead-of-127001\
resolveAddress=\"0.0.0.0\"\
' ${dataFile}
  echo ".    Adding resolveAddress to conf file..." | sendmsg
  somethingAdded=true
fi

#end resolveAddress area


#add dnsmasqHome area
if ! grep -q "dnsmasqHome" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#Where do you want to put the dnsmasq config files this script makes?\
#/etc/dnsmasq.d is the default setting.\
#This would only need to be changed if you are configuring this script to update\
#a secondary instance of dnsmasq.\
#Do not put a trailing slash here.\
dnsmasqHome=\"\/etc\/dnsmasq.d\"\
' ${dataFile}
  echo ".    Adding dnsmasqHome to conf file..." | sendmsg
  somethingAdded=true
fi

#end dnsmasqHome area


#add dnsmasqName area
if ! grep -q "dnsmasqName" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#What is the name of the dnsmasq instance in \/etc\/init.d\/ that we are going to restart?\
#dnsmasq is the default setting.\
#This would only need to be changed if you are configuring this script to update\
#a secondary instance of dnsmasq and you have the init.d file named something else.\
#We are going to call "\/etc/\init.d\/<this filename here> force-reload" using this name.\
dnsmasqName=\"dnsmasq\"\
' ${dataFile}
  echo ".    Adding dnsmasqName to conf file..." | sendmsg
  somethingAdded=true
fi

#end dnsmasqName area


#curlMaxTime area
if ! grep -q "curlMaxTime" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#What is the time limit (in seconds) for each file download?\
#This is to set a limit for curl when downloading from each source.\
#Without a limit curl would wait forever for a file to finish.\
#This sets the --max-time parameter for curl.\
#If you have a slower connection, you may need to increase the default 60 seconds.\
curlMaxTime=\"60\"\
' ${dataFile}
  echo ".    Adding curlMaxTime to conf file..." | sendmsg
  somethingAdded=true
fi
#end curlMaxTime area


#dnsmasqOptions area
if ! grep -q "dnsmasqOptions" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#Are there any options that you want to pass to dnsmasq?\
#Dnsmasq options can be found at http:\/\/www.thekelleys.org.uk\/dnsmasq\/docs\/dnsmasq-man.html.\
#Any options put here will be provided to dnsmasq in a .conf file located in the home folder specified above.\
#The options will be read by dnsmasq when this script restarts it after processing.\
#This is a ; delmited list, not not include the leading -- just the options themselves.\
#If you do not want to specify any options, keep this empty.\
#If you do want to specify any options, place them between the \" marks.\
#An example is: \"log-queries;some-other-option\"\
#The above example would enable dnsmasq logging of each query, and also some-other-option as well.\
dnsmasqOptions=\"\"\
' ${dataFile}
  echo ".    Adding dnsmasqOptions to conf file..." | sendmsg
  somethingAdded=true
fi
#end dnsmasqOptions area


#useAddnHosts area
if ! grep -q "useAddnHosts" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#Shall the dnsmasq addn-hosts directive be used?\
#There are two ways providing url host entries.\
#1) legacy mode: \"address=/url.tld/0.0.0.0\"\
#2) addn-hosts: \"0.0.0.0 url.tld\"\
#addn-hosts is faster\
#https:\/\/www.reddit.com\/r\/sysadmin\/comments\/beqbcj\/dnsmasq_is_very_slow_due_to_adblocking\/\
useAddnHosts=true\
' ${dataFile}
  echo ".    Adding useAddnHosts to conf file..." | sendmsg
  somethingAdded=true
fi
#end useAddnHosts area

#postRun area
if ! grep -q "postRun" ${dataFile}; then
  sed -i '/################################/ i \
\
\
\
#***NEW OPTION***\
#filename that will be run after the script finishes. If it does not exist it will not be run.\
postRun="'"${scriptHome}"'/getBlacklistPostRun.sh"\
' ${dataFile}
  echo ".    Adding postRun to conf file..." | sendmsg
  somethingAdded=true
fi
#end postRun area


#delete the usenonshalla area
if grep -q "usenonshalla" ${dataFile}; then
  sed -i -e '/do you want to use the non-shallalist/d' -e '/readonly usenonshalla/d' ${dataFile}
  echo ".    Removing usenonshalla from conf file..." | sendmsg
  somethingAdded=true
fi
#end usenonshalla area


#delete the useshalla area
if grep -q "useshallalist" ${dataFile}; then
  sed -i -e '/do you want to use the shallalist/d' -e '/readonly useshallalist/d' ${dataFile}
  echo ".    Removing useshallalist from conf file..." | sendmsg
  somethingAdded=true
fi
#end usenonshalla area

#update user-defined source URLs area
if ! grep -q "This URL can be a zip file containing one or more files" ${dataFile}; then
  sed -i '/#If no URLs are defined it will be skipped during processing./ i \
#This URL can be a zip file containing one or more files.' ${dataFile}
  somethingAdded=true
fi
#end update user-defined source URLs area

#https update to sources
sed -i 's/http:\/\/hosts-file.net\/ad_servers.txt/https:\/\/hosts-file.net\/ad_servers.txt/g' ${dataFile}

sed -i 's/http:\/\/pgl.yoyo.org\/adservers\/serverlist.php/https:\/\/pgl.yoyo.org\/adservers\/serverlist.php/g' ${dataFile}

sed -i 's/http:\/\/someonewhocares.org\/hosts\/hosts/https:\/\/someonewhocares.org\/hosts\/hosts/g' ${dataFile}
#end https update to sources

#update malware-domains source
sed -i 's/https:\/\/mirror1.malwaredomains.com\/files\/justdomains/http:\/\/malware-domains.com\/files\/justdomains.zip/g' ${dataFile}
#end update malware-domains source

#update hosts-file.net source
sed -i 's/https:\/\/hosts-file.net\/ad_servers.txt/https:\/\/raw.githubusercontent.com\/evankrob\/hosts-filenetrehost\/master\/ad_servers.txt/g' ${dataFile}
#end update hosts-file.net source




#end conf file updates

if [ "$somethingAdded" = true ] ; then
	cleanup
	cleanupOthers
	echo " " | sendmsg
	echo ".    Configuration options were added to the configuration file at ${dataFile}." | sendmsg
	echo ".    The Blacklist Hosts have NOT been updated." | sendmsg
	echo ".    Next time the script runs the Blacklist Hosts will be updated." | sendmsg
	echo ".    This is so you can adjust settings in ${dataFile} before the first updates." | sendmsg
	echo ".    Once you have made changes (or not if you want the defaults), run this script again." | sendmsg
	echo " " | sendmsg
	exit
fi

declare -A URLarray
declare -A ProvidedURLarray
declare -A ShallaArray

source ${dataFile}


#Download and merge multiple hosts files to ${sTmpNewHosts}

downloadErrors=0

## one to test with
#even if all other sources are disabled you will have one record
echo "#debugging: getBlacklistHosts.sh Testing record start" > "${sTmpNewHosts}"
echo "testMyLocalUSGDns.com" >> "${sTmpNewHosts}"
echo "#debugging: getBlacklistHosts.sh Testing record end" >> "${sTmpNewHosts}"


if [ ! -f ${userblacklist} ]; then
	echo ".    Not using a user-defined blacklist..." | sendmsg
else
    echo ".    Using a user-defined blacklist..." | sendmsg
	echo ".    Cleaning user-defined blacklist..." | sendmsg
	sed -i -e "s/[[:space:]]\+//g" ${userblacklist}
	sed -i '/^ *$/d' ${userblacklist}
	echo ".    Adding user-defined blacklist..." | sendmsg
	echo "#debugging: user-defined blacklist records start" >> "${sTmpNewHosts}"
	lastCount=$(wc -l < ${sTmpNewHosts});
	#lastCount=$((lastCount-3));
	cat ${userblacklist} >> "${sTmpNewHosts}"
	thisCount=$(wc -l < ${sTmpNewHosts})
	echo ".    Got "$((thisCount-lastCount))" records. Raw data count now: "${thisCount}| sendmsg
	echo "#debugging: user-defined blacklist records end" >> "${sTmpNewHosts}"
fi



if [ ${#URLarray[@]} -eq 0 ]; then
    echo ".    Not using any user-defined source URLs..." | sendmsg
else
	echo ".    Using user-defined source URLs..." | sendmsg
	for URLarray_idx in ${!URLarray[@]}; do
		echo ".    Downloading user-defined URL $URLarray_idx - ${URLarray[$URLarray_idx]}..." | sendmsg
		echo "#debugging: user-defined source: ${URLarray[$URLarray_idx]} records start" >> "${sTmpNewHosts}"
		lastCount=$(wc -l < ${sTmpNewHosts});
		lastCount=$((lastCount-1));
		#curl --silent --max-time ${curlMaxTime} ${URLarray[$URLarray_idx]} >> "${sTmpNewHosts}"
		curlError=$((curl -# --silent --show-error --max-time ${curlMaxTime} -o ${sTmpCurlDown} ${URLarray[$URLarray_idx]} >/dev/null) 2>&1)
		curlCode=$?
		if [ $curlCode -eq 0 ]; then
			#unzip if need be
			if [ ${URLarray[$URLarray_idx]: -4} == ".zip" ]; then
				echo ".    Unzipping file..." | sendmsg
				rm -f ${sTmpCurlUnzip}/*
				unzipError=$((/usr/bin/unzip -qq ${sTmpCurlDown} -d ${sTmpCurlUnzip} >/dev/null) 2>&1)
				zipCode=$?
				if [ $zipCode -eq 0 ]; then
					> ${sTmpCurlDown}
					cat ${sTmpCurlUnzip}/* >> ${sTmpCurlDown}
				else
				echo ".    Unzip had an error of code "$zipCode| sendmsg
				fi
			fi
		
			cat ${sTmpCurlDown} >> ${sTmpNewHosts}
		else
			if [ $curlCode -ne 0 ]; then
				((downloadErrors++))
				echo ".    Warning from "$curlError| sendmsg
			fi 
		
			if [ $curlCode -eq 28 ]; then
				echo ".    The curlMaxTime of ${curlMaxTime} in the conf file is too small"| sendmsg
			fi
		fi

		thisCount=$(wc -l < ${sTmpNewHosts})
		echo ".    Got "$((thisCount-lastCount))" records. Raw data now: "${thisCount}| sendmsg
		echo "#debugging: user-defined source: ${URLarray[$URLarray_idx]} records end" >> "${sTmpNewHosts}"
	done
fi



if [ ${#ProvidedURLarray[@]} -eq 0 ]; then
    echo ".    Not using any script-provided source URLs..." | sendmsg
else
	echo ".    Using script-provided source URLs..." | sendmsg
	for ProvidedURLarray_idx in ${!ProvidedURLarray[@]}; do
		echo ".    Downloading script-provided URL $ProvidedURLarray_idx - ${ProvidedURLarray[$ProvidedURLarray_idx]}..." | sendmsg
		echo "#debugging: script-provided source: ${ProvidedURLarray[$ProvidedURLarray_idx]} records start" >> "${sTmpNewHosts}"
		lastCount=$(wc -l < ${sTmpNewHosts});
		lastCount=$((lastCount-1));
		#curl --silent --max-time ${curlMaxTime} ${ProvidedURLarray[$ProvidedURLarray_idx]} >> "${sTmpNewHosts}"
		curlError=$((curl -# --silent --show-error --max-time ${curlMaxTime} -o ${sTmpCurlDown} ${ProvidedURLarray[$ProvidedURLarray_idx]} >/dev/null) 2>&1)
		curlCode=$?
		if [ $curlCode -eq 0 ]; then
			#unzip if need be
			if [ ${ProvidedURLarray[$ProvidedURLarray_idx]: -4} == ".zip" ]; then
				echo ".    Unzipping file..." | sendmsg
				rm -f ${sTmpCurlUnzip}/*
				unzipError=$((/usr/bin/unzip -qq ${sTmpCurlDown} -d ${sTmpCurlUnzip} >/dev/null) 2>&1)
				zipCode=$?
				if [ $zipCode -eq 0 ]; then
					> ${sTmpCurlDown}
					cat ${sTmpCurlUnzip}/* >> ${sTmpCurlDown}
				else
				echo ".    Unzip had an error of code "$zipCode| sendmsg
				fi
			fi
		
			cat ${sTmpCurlDown} >> ${sTmpNewHosts}
		else
			if [ $curlCode -ne 0 ]; then
				((downloadErrors++))
				echo ".    Warning from "$curlError| sendmsg
			fi 
		
			if [ $curlCode -eq 28 ]; then
				echo ".    The curlMaxTime of ${curlMaxTime} in the conf file is too small"| sendmsg
			fi
		fi
		
		
		thisCount=$(wc -l < ${sTmpNewHosts})
		echo ".    Got "$((thisCount-lastCount))" records. Raw data count now: "${thisCount}| sendmsg
		echo "#debugging: script-provided source: ${ProvidedURLarray[$ProvidedURLarray_idx]} records end" >> "${sTmpNewHosts}"
	done
fi



if [ "$enableDebugging" = true ] ; then
	echo ".    Creating debugging file nonFilteredHosts..." | sendmsg
	cp ${sTmpNewHosts} ${debugDirectory}/nonFilteredHosts
fi
	

#Convert hosts text to the UNIX format. Strip comments, blanklines, and invalid characters.
#Replaces tabs/spaces with a single space, remove localhost entries.
#There will be at least one here due to the hardcoded testMyLocalUSGDns.com hostname
echo ".    Sanitizing downloaded blacklists..." | sendmsg
echo ".    Raw data stage 1 count: "$(wc -l < ${sTmpNewHosts})| sendmsg

#pre-remove subdirectories and lines with no '.' 
sed -i -e 's~http[s]*://~~g' ${sTmpNewHosts}
sed -i -e '/\./!d' -e 's/\/.*$//' -e 's/\-*//' -e 's/^www[[:digit:]]*\.//' -e 's/\.*//' -e 's/\.$//' ${sTmpNewHosts}


exec 3>"${sTmpAdHosts}"
sed -r -e "s/$(echo -en '\r')//g" \
       -e '/^#/d' \
       -e 's/#.*//g' \
       -e 's/[^a-zA-Z0-9\.\_\t \-]//g' \
       -e 's/(\t| )+/ /g' \
       -e 's/^127\.0\.0\.1/0.0.0.0/' \
       -e '/ localhost( |$)/d' \
       -e '/^ *$/d' \
        "${sTmpNewHosts}" >&3
exec 3>&-

echo ".    Raw data stage 2 count: "$(wc -l < ${sTmpNewHosts})| sendmsg

if [ ${#ShallaArray[@]} -eq 0 ]; then
    echo ".    Not using any Shallalist categories..." | sendmsg
else
	
	echo ".    Downloading Shallalist MD5 sum..." | sendmsg

	#curl --silent --max-time ${curlMaxTime} -# -o ${sTmpShallaMD5} http://www.shallalist.de/Downloads/shallalist.tar.gz.md5
	curlError=$((curl -# --silent --show-error --max-time ${curlMaxTime} -o ${sTmpShallaMD5} http://www.shallalist.de/Downloads/shallalist.tar.gz.md5 >/dev/null) 2>&1)
		curlCode=$?
		if [ $curlCode -ne 0 ]; then
			((downloadErrors++))
			echo ".    Warning from "$curlError| sendmsg
		fi
		
		if [ $curlCode -eq 28 ]; then
			echo ".    The curlMaxTime of ${curlMaxTime} in the conf file is too small"| sendmsg
		fi

	if [ ! -f ${sTmpShallaMD5} ]; then
		new_shallaMD5='MD5 download error'
	else
		new_shallaMD5=$(cat ${sTmpShallaMD5} | awk -F' ' '{print $1}')
	fi

	if [ -z ${current_shallaMD5+x} ]; then
		#we do not have record of the current MD5
		current_shallaMD5="none"
	fi

	if [ "${new_shallaMD5}" != "${current_shallaMD5}" ] || [ ! -f ${sTmpGzips} ]; then
		#either the MD5 has changed, or we do not have the shallalist from the last download.
		current_shallaMD5=${new_shallaMD5}

		echo ".    MD5 sum does not match our last download..." | sendmsg
		echo ".    Downloading Shallalist blacklist..." | sendmsg

		#curl --silent -# --max-time ${curlMaxTime} -o ${sTmpGzips} http://www.shallalist.de/Downloads/shallalist.tar.gz
		curlError=$((curl -# --silent --show-error --max-time ${curlMaxTime} -o ${sTmpGzips} http://www.shallalist.de/Downloads/shallalist.tar.gz >/dev/null) 2>&1)
		curlCode=$?
		if [ $curlCode -ne 0 ]; then
			((downloadErrors++))
			echo ".    Warning from "$curlError| sendmsg
		fi
		
		if [ $curlCode -eq 28 ]; then
			echo ".    The curlMaxTime of ${curlMaxTime} in the conf file is too small"| sendmsg
		fi

	else
		echo ".    MD5 sum matches our last download..." | sendmsg
		echo ".    Using already downloaded Shallalist blacklist..." | sendmsg
	fi

	if [ "$downloadErrors" -gt 2 ] ; then
		cleanup
		cleanupOthers
		echo " " | sendmsg
		echo ".    There were ${downloadErrors} errors encountered during downloading." | sendmsg
		echo ".    Processing has been stopped." | sendmsg
		echo ".    The Blacklist Hosts have NOT been updated." | sendmsg
		echo ".    This may be due to a network outage." | sendmsg
		echo " " | sendmsg
		exit
	fi

	echo ".    Processing Shallalist blacklist..." | sendmsg

		
	for ShallaArray_idx in ${!ShallaArray[@]}; do
		echo ".    Processing Shallalist category: ${ShallaArray[$ShallaArray_idx]}..." | sendmsg
		tarError=$((tar --directory ${sTmpExtracts} -zxvf ${sTmpGzips} BL/${ShallaArray[$ShallaArray_idx]}/domains >/dev/null) 2>&1)
		if [ $? -eq 0 ]; then
			echo ".    Tar extract successful for ${ShallaArray[$ShallaArray_idx]}($?)" | sendmsg
		else
			echo ".    Tar extract warning for ${ShallaArray[$ShallaArray_idx]} ($?) error was: $tarError" | sendmsg
		fi
		
		if [ -f ${sTmpExtracts}/BL/${ShallaArray[$ShallaArray_idx]}/domains ]; then
		echo ".    Continuing processing of ${ShallaArray[$ShallaArray_idx]}. File found in download." | sendmsg
			cat ${sTmpExtracts}/BL/${ShallaArray[$ShallaArray_idx]}/domains >> ${sTmpAdHosts}		
		else
			echo ".    Skipping processing of ${ShallaArray[$ShallaArray_idx]}. File not found in download." | sendmsg
		fi
		
		if [ "$enableDebugging" = true ] ; then
			echo ".    Adding Shallalist category ${ShallaArray[$ShallaArray_idx]} to debugging file nonFilteredHosts..." | sendmsg
			echo "#debugging: Shallalist category: ${ShallaArray[$ShallaArray_idx]} records start" >> ${debugDirectory}/nonFilteredHosts
			cat ${sTmpExtracts}/BL/${ShallaArray[$ShallaArray_idx]}/domains >> ${debugDirectory}/nonFilteredHosts
			echo "#debugging: Shallalist category: ${ShallaArray[$ShallaArray_idx]} records end" >> ${debugDirectory}/nonFilteredHosts
		fi
	done
	
fi

echo ".    Raw data stage 3 count after shalla: "$(wc -l < ${sTmpAdHosts})| sendmsg

echo ".    Converting full blacklist..." | sendmsg
/bin/sed -i -r -e 's/0.0.0.0 //g' ${sTmpAdHosts}  
/bin/sed -i -r -e '/^[0-9\.]*$/d' ${sTmpAdHosts}  
/bin/sed -i -e "s/[[:space:]]\+//g" ${sTmpAdHosts}

#make the list unique
/usr/bin/sort -u ${sTmpAdHosts} -o ${sTmpAdHosts}


echo ".    Creating list of single domains..." | sendmsg
#process out single domains
grep -E "^[^.]*+.[^.]*+$" ${sTmpAdHosts} > ${sTmpDomainss}
#so we have a filter even if no whitelist
cp ${sTmpDomainss} ${sTmpSubFilters}

if [ -f ${whitelist} ]; then
	echo ".    Using a whitelist..." | sendmsg
	echo ".    Cleaning whitelist..." | sendmsg
	sed -i -e "s/[[:space:]]\+//g" ${whitelist}
	sed -i '/^ *$/d' ${whitelist}

	#process out sub domains from whitelist
	grep -Ev "^[^.]*+.[^.]*+$" ${whitelist} > ${sTmpWhiteHosts}
	
	#get list of domains only
	grep -E "^[^.]*+.[^.]*+$" ${whitelist} > ${sTmpWhiteNonSub}
	
	#add start of dnsmsaq config command
	/bin/sed -i -e 's/^/server=\//' ${sTmpWhiteHosts}
	#add command ending
	/bin/sed -i -e "s/$/\/\#/" ${sTmpWhiteHosts}
	
	#remove any whitelisted non wildcards from sTmpDomainss
	
	sed '/\*/!d' ${whitelist} > ${sTmpWhiteNoneWild}
	
	#add start and end
	/bin/sed -i -e 's/^/\$/' -e 's/$/\$/' ${sTmpWhiteNoneWild}
	/bin/sed -i -e 's/^/\$/' -e 's/$/\$/' ${sTmpDomainss}
	/bin/grep -v -F -f ${sTmpWhiteNoneWild} ${sTmpDomainss} > ${sTmpDomains2s}
	
	
	#remove whitelisted domains from single domain blacklist filter to keep the subs in blacklist
	#add start and end
	/bin/sed -i -e 's/^/\$/' -e 's/$/\$/' ${sTmpWhiteNonSub}
	/bin/grep -v -F -f ${sTmpWhiteNonSub} ${sTmpDomainss} > ${sTmpSubFilters}
	
	
	#remove start and end
	#### end /bin/sed -i -e "s/\$\+//g"
	/bin/sed -i -e "s/\$\+//g" ${sTmpWhiteNoneWild}
	/bin/sed -i -e "s/\$\+//g" ${sTmpDomainss}
	/bin/sed -i -e "s/\$\+//g" ${sTmpDomains2s}
	/bin/sed -i -e "s/\$\+//g" ${sTmpWhiteNonSub}
	/bin/sed -i -e "s/\$\+//g" ${sTmpSubFilters}
	
	
	cat ${sTmpDomains2s} > ${sTmpDomainss}
	
fi

#add start of string marker to single domain list
/bin/sed -i -e 's/$/\$/' ${sTmpDomainss}


#add end of string marker to the blacklist list
/bin/sed -i -e 's/$/\$/' ${sTmpAdHosts}

iSingleDomainCount="$(wc -l "${sTmpDomainss}" | cut -d ' ' -f 1)"
echo ".    Found ${iSingleDomainCount} single domains..." | sendmsg

#add leading dot to single domain list
/bin/sed -i -e 's/^/\./' ${sTmpSubFilters}

echo ".    Removing sub-domains..." | sendmsg
#remove any subdomains of our domains list since we are blocking as domains
/bin/grep -v -F -f ${sTmpSubFilters} ${sTmpAdHosts} > ${sTmpCleaneds}


if [ "$enableDebugging" = true ] ; then
	echo ".    Creating debugging file singleDomains..." | sendmsg
	#remove the end of string marker
	/bin/sed -i -e "s/\$\+//g" ${sTmpDomainss}
	cp ${sTmpDomainss} ${debugDirectory}/singleDomains
		
fi

#add cleaned to domain list
cat ${sTmpCleaneds} >> ${sTmpDomainss}


#remove the end of string marker
/bin/sed -i -e "s/\$\+//g" ${sTmpDomainss}

#safety check remove sub-directories
/bin/sed -i 's/\/.*//' ${sTmpDomainss}

#make the list unique
/usr/bin/sort -u ${sTmpDomainss} -o ${sTmpDomainss}

#safety check remove any blank lines and lines with no dot
/bin/sed -i '/^[^.]*$/d' ${sTmpDomainss}

#replace our original list with the cleaned list
cat ${sTmpDomainss} > ${sTmpAdHosts}


old_count=${current_count}

if [ "$enableDebugging" = true ] ; then
	echo ".    Creating debugging file filteredHosts..." | sendmsg
	cp ${sTmpAdHosts} ${debugDirectory}/filteredHosts
fi

#Verify parsing of the hostlist succeeded, at least 1 blacklist entries are expected.
iBlackListCount="$(wc -l "${sTmpAdHosts}" | cut -d ' ' -f 1)"
if [ "${iBlackListCount}" -lt "1" ]; then
    echo ".    ${iBlackListCount} blacklist entries discovered. Minimum of 1 expected. Aborting." | sendmsg
    cleanup
	cleanupOthers
    exit 3
fi

	

if [ ! -f ${whitelist} ]; then
	echo ".    Not using a whitelist..." | sendmsg
	#clean the resolveAddress
	cleanResolveAddress="$(echo -e "${resolveAddress}" | tr -d '[:space:]')"
	echo ".    Using host ${cleanResolveAddress}" | sendmsg
	if [ "$useAddnHosts" = true ] ; then
	  /bin/sed -i -e "s/^/${cleanResolveAddress} /" ${sTmpAdHosts}
	else
	  /bin/sed -i -e 's/^/address=\//' ${sTmpAdHosts}
	  /bin/sed -i -e "s/$/\/${cleanResolveAddress}/" ${sTmpAdHosts}
  fi

  cat ${sTmpAdHosts} > ${sTmpHostSplitterD}/fullhosts
	current_count=$(wc -l < ${sTmpAdHosts})
else
	mathbeforewhite=$(wc -l < ${sTmpAdHosts})
	echo ".    Processing whitelist..." | sendmsg
	#add the whitelist found single domains to the empty sTmpWhiteDomains file
	#there used to be data in sTmpWhiteDomains at this point
	#but the whitelist logic changed that.
	#this is to maintain the used var name moving forward
	cat ${whitelist} >> ${sTmpWhiteDomains}
	
	#make the list unique
	/usr/bin/sort -u ${sTmpWhiteDomains} -o ${sTmpWhiteDomains}
	
	#add start and end of string marker 
	/bin/sed -i -e 's/^/\$/' -e 's/$/\$/' ${sTmpWhiteDomains}
	/bin/sed -i -e 's/^/\$/' -e 's/$/\$/' ${sTmpAdHosts}
	
	#remove start of line marker and * from wildcards
	/bin/sed -i 's/^\$\*[\.]*//g' ${sTmpWhiteDomains}

  /bin/grep -v -F -f  ${sTmpWhiteDomains} ${sTmpAdHosts} > ${sTmpHostSplitterD}/fullhosts

	
	#remove start and end string markers from the list of whitelist domains
	/bin/sed -i -e "s/\$\+//g" ${sTmpHostSplitterD}/fullhosts
	
	current_count=$(wc -l < /${sTmpHostSplitterD}/fullhosts)
	#clean the resolveAddress
	cleanResolveAddress="$(echo -e "${resolveAddress}" | tr -d '[:space:]')"

	if [ "$useAddnHosts" = true ] ; then
	  /bin/sed -i -e "s/^/${cleanResolveAddress} /" ${sTmpHostSplitterD}/fullhosts
	else
    #add start of dnsmsaq config command
    /bin/sed -i -e 's/^/address=\//' ${sTmpHostSplitterD}/fullhosts
    #add command ending
    /bin/sed -i -e "s/$/\/${cleanResolveAddress}/" ${sTmpHostSplitterD}/fullhosts
  fi

	if [ "${current_count}" -lt "1" ]; then
      echo ".    ${current_count} blacklist entries found after processing whitelist. Something went wrong, was everything whitelisted? Aborting." | sendmsg
      cleanup
	  cleanupOthers
      exit 3
    fi
fi


if [ "$enableDebugging" = true ] ; then
	echo ".    Creating debugging file finalHosts..." | sendmsg
	cp ${sTmpHostSplitterD}/fullhosts ${debugDirectory}/finalHosts
	
	if [ -f ${whitelist} ]; then
		echo ".    Creating debugging file finalWhite..." | sendmsg
		cp ${sTmpWhiteHosts} ${debugDirectory}/finalWhite
	fi
fi


echo -e "Old count: ${old_count}" > ${messageFile};
echo ".    Old count: ${old_count}..." | sendmsg

if [ ! -f ${whitelist} ]; then
	echo -e "New count (not using a whitelist): ${current_count}" >> ${messageFile};
	echo ".    New count (not using a whitelist): ${current_count}..." | sendmsg
else
	echo -e "New count before whitelist processing: ${mathbeforewhite}" >> ${messageFile};
	echo ".    New count before whitelist processing: ${mathbeforewhite}..." | sendmsg
	echo -e "New count after whitelist processing: ${current_count}" >> ${messageFile};
	echo ".    New count after whitelist processing: ${current_count}..." | sendmsg
fi


mathold=${old_count}
mathnew=${current_count}
mathchange=$((mathnew-mathold))
if [ "${mathchange}" -gt "0" ]; then
	mathchange="+"${mathchange}
fi

echo -e "Old count to new count change: ${mathchange}" >> ${messageFile};
echo ".    Old count to new count change: ${mathchange}..." | sendmsg




if [ "$stopBeforeConfig" = true ] ; then
  cleanup
  cleanupOthers
  echo ".    " | sendmsg
  echo ".    Processing has ended... 'stopBeforeConfig' is set to true in the configuration file..." | sendmsg
  echo ".    The Blacklist Hosts have NOT been updated." | sendmsg
  echo ".    " | sendmsg
  endTime=`date +%s`
  runTimeSec=$((endTime-startTime))
  runTimeMin=$((runTimeSec/60))
  runTimeRemainder=$((runTimeSec-(runTimeMin*60)))
  runTime=$runTimeSec" seconds or "$runTimeMin" minutes "$runTimeRemainder" seconds"
  echo ".    Script execution time: $runTime" | sendmsg
  exit
fi


if [ "$recordHistory" = true ] ; then
	echo ".    Recording history count..." | sendmsg
	if [ -f ${historycountFile} ]; then
		echo -n "," >> ${historycountFile}
	fi
	echo ${current_count}| tr -d '\n' >> ${historycountFile}
fi


rm -rf ${sTmpExtracts}



echo ".    Splitting blacklist..." | sendmsg

/usr/bin/split -l 10000 ${sTmpHostSplitterD}/fullhosts ${sTmpHostSplitterD}/blackhost

for f in ${dnsmasqHome}/blackhost*; do
    [ -e "$f" ] && rm ${dnsmasqHome}/blackhost*
    break
done

if [ "$useAddnHosts" = true ] ; then
  mkdir -p ${dnsmasqHome}/hosts/
  cp ${sTmpHostSplitterD}/blackhost* ${dnsmasqHome}/hosts/
else
  cp ${sTmpHostSplitterD}/blackhost* ${dnsmasqHome}/
fi
rm -rf ${sTmpHostSplitterD}



for f in ${dnsmasqHome}/whitehost*; do
    [ -e "$f" ] && rm ${dnsmasqHome}/whitehost*
    break
done

if [ -f ${whitelist} ]; then
	/usr/bin/split -l 10000 ${sTmpWhiteHosts} ${dnsmasqHome}/whitehost
fi


#clear old optionsFile
rm -f ${dnsmasqHome}/${optionsFileName}

#create options file if needed
while IFS=';' read -ra ADDR; do
    if [ ${#ADDR[@]} -ne 0 ]; then
          echo ".    Custom dnsmasq options found in conf file, generating config ${dnsmasqHome}/${optionsFileName}..." | sendmsg
		else
		  echo ".    No custom dnsmasq options found in conf file..." | sendmsg
        fi
      for i in "${ADDR[@]}"; do
          echo "$i" >> ${dnsmasqHome}/${optionsFileName}
      done
    if [ "$useAddnHosts" = true ] ; then
      echo ".    Adding addn-hosts directive to config ${dnsmasqHome}/${optionsFileName}..." | sendmsg
      echo "addn-hosts=${dnsmasqHome}/hosts" >> ${dnsmasqHome}/${optionsFileName}
    fi
done <<< "$dnsmasqOptions"


#Cleanup.
cleanup

endTime=`date +%s`
runTimeSec=$((endTime-startTime))
runTimeMin=$((runTimeSec/60))
runTimeRemainder=$((runTimeSec-(runTimeMin*60)))
runTime=$runTimeSec" seconds or "$runTimeMin" minutes "$runTimeRemainder" seconds"
echo ".    Script execution time: $runTime" | sendmsg


echo ".    Restarting ${dnsmasqName} (output on next line)..." | sendmsg
/etc/init.d/${dnsmasqName} force-reload  | sendmsg
echo " " | sendmsg

if [ -w "${postRun}" ]; then
	echo ".    Found PostRun file (${postRun}) calling it..." | sendmsg
    ${postRun}
fi


if [ "$sendEmails" = true ] ; then
echo -e "To: ${emailtoaddr}\n\
From: ${emailfromname}<${emailfromaddr}>\n\
Subject: ${emailsubject}\n\
MIME-Version: 1.0\n\
Content-Type: text/html\n\
Content-Disposition: inline\n\
\n\
<html>\n\
<body>\n\
<pre style='font: monospace'>" > ${messageHeader};

echo -e "blacklisthosts updated at "$(date)"\n" >> ${messageHeader};
echo -e "Script execution time: $runTime\n" >> ${messageHeader};
fi

if [ "$sendEmails" = true ] ; then
	echo -e "\n" > ${messageFooter};
	echo -e "Log from this run:" >> ${messageFooter};
	cat ${logFile} >> ${messageFooter}
	echo -e "</pre></body></html>" >> ${messageFooter}
	cat ${messageHeader} ${messageFile} ${messageFooter} | sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[mGK]//g" | sed "s/\x0f//g" | /usr/sbin/ssmtp ${emailtoaddr};
fi

echo -e "\n" >> ${logFile};
cat ${messageFile} >> ${logFile}

# update the data file
/bin/sed -i '/current_count=/d' ${dataFile}
/bin/sed -i '/old_count=/d' ${dataFile}
/bin/sed -i '/current_shallaMD5=/d' ${dataFile}
echo -e "current_count=\"$current_count\"" >> ${dataFile}
echo -e "old_count=\"$old_count\"" >> ${dataFile}
echo -e "current_shallaMD5=\"$current_shallaMD5\"" >> ${dataFile}

if [ -t 1 ]; then
		echo -e " "
	    echo -e "getBlackListHosts ${version} completed, these messages also recorded at ${logFile}."
		echo -e "Script execution time: $runTime" 
		echo -e " "
fi

cleanupOthers


##END getBlacklistHosts
