#!/bin/bash

#
# This file is part of quagga-config-loader.
#
# quagga-config-loader, a configuration incubator.
# Copyright (C) <2015> <Andreas Unterkircher>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.

# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#

shopt -s extglob

#
#
#
test -e functions.sh || \
   { echo "Where is my functions.sh?"; exit 1; }
. functions.sh

#
# quagga-config-loader configuration
#
test -e quagga_config_loader.cfg || \
   { echo "Where is my quagga_config_loader.cfg?"; exit 1; }
. quagga_config_loader.cfg

check_requirements;
check_privileges;
check_configuration;
check_parameters "${@}"

readonly DAEMON_CONFIG=${DAEMON}.conf
readonly RUNNING_CONFIG=${QUAGGA_CONF_DIR}/${DAEMON_CONFIG}.conf
readonly PUPPET_CONFIG=${DAEMON_CONFIG}.puppet
readonly PRESTAGE_CONFIG=${DAEMON_CONFIG}.prestage

#
# save running configuration
#
if pgrep ${DAEMON} >/dev/null; then

   #
   # check if we can enter the daemon's configuration mode, otherwise we should not continue
   #
   mapfile -t OUTPUT < <(${VTYSH} -d ${DAEMON} -c 'configure terminal')
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi

   if [ "x${OUTPUT[0]}" == "xVTY configuration is locked by other VTY" ]; then
      echo; echo; echo
      log_failure_msg "Can not enter 'configure terminal' for daemon '${DAEMON}' because it's locked! Exiting."
      exit 1
   fi
   unset OUTPUT

   #
   # issue a 'write' command
   #
   ${VTYSH} -d ${DAEMON} -c "write" 2>&1 >/dev/null
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
fi

#
# check the new configuration
#
if [ ! -e ${PUPPET_CONFIG} ]; then
   log_failure_msg "Configuration ${PUPPET_CONFIG} does not exist!"
   exit 1
fi

#
# prepare the prestage file
#
if [ -e ${PRESTAGE_CONFIG} ]; then
   rm ${PRESTAGE_CONFIG}
fi
cp ${PUPPET_CONFIG} ${PRESTAGE_CONFIG}
chown quagga.root ${PRESTAGE_CONFIG}
chmod 640 ${PRESTAGE_CONFIG}

#
# for OSPF, replace AREAPASS with the actual password
#
if [ "x${DAEMON}" == "xospfd" ]; then

   if [ ! -e /etc/quagga/ospf_area_password ]; then
      log_failure_msg "Should handle ${DAEMON} but /etc/quagga/ospf_area_password is missing!"
      exit 1
   fi

   if grep -qs AREAPASS ${PRESTAGE_CONFIG}; then
      OSPF_AREA_PW=$(cat /etc/quagga/ospf_area_password)
      sed -i "s/ AREAPASS$/ ${OSPF_AREA_PW}/g" ${PRESTAGE_CONFIG}
      unset OSPF_AREA_PW
   fi
fi

#
# check if actions have to be actually taken
#
if [ -e ${RUNNING_CONFIG} ]; then
   if diff --ignore-matching-lines='^!' ${RUNNING_CONFIG} ${PRESTAGE_CONFIG} >/dev/null; then
      # running config matches puppet generated config, no action required
      exit 0
   fi
fi

#
# test if new configuration pass quagga's daemon configuration check
#
if [ ! -x /usr/lib/quagga/${DAEMON} ]; then
   log_failure_msg "/usr/lib/quagga/${DAEMON} does not exist or is not executable!"
   exit 1
fi

/usr/lib/quagga/${DAEMON} -f ${PRESTAGE_CONFIG} -C
if [ "x${?}" != "x0" ]; then
   log_failure_msg "${DAEMON} failed on validating ${PRESTAGE_CONFIG}!"
   exit 1
fi

#
# the easy part - if ${DAEMON} isn't running, we just replace the running configuration
# with the prestaged one and exit.
#
if ! pgrep ${DAEMON} >/dev/null; then
   [ -e ${RUNNING_CONFIG} ] && rm ${RUNNING_CONFIG}
   cp ${PRESTAGE_CONFIG} ${RUNNING_CONFIG}
   chown quagga.quagga ${RUNNING_CONFIG}
   chmod 640 ${RUNNING_CONFIG}
   exit 0
fi

################
#
# the harder part, act daemon specific - unload vanished configurations and reload
#
################

if [ ! -e ${RUNNING_CONFIG} ]; then
   log_failure_msg "${DAEMON} seems to be active but there is no running configuration (${RUNNING_CONFIG}). Better stopping here."
   exit 1
fi

declare -a PRE_CMDS=()

if [ "x${DAEMON}" == "xzebra" ]; then
   declare -A GROUPING_CMDS=( ['interface']='^interface' ['route-map']='^route-map' )
elif [ "x${DAEMON}" == "xospfd" ]; then
   declare -A GROUPING_CMDS=( ['interface']='^interface' ['route-map']='^route-map' ['router ospf']='^router[[:blank:]]ospf$' )
elif [ "x${DAEMON}" == "xospf6d" ]; then
   declare -A GROUPING_CMDS=( ['interface']='^interface' ['router ospf6']='^router[[:blank:]]ospf6$' )
elif [ "x${DAEMON}" == "xbgpd" ]; then
   # special case, we need to grep out the AS number from that command
   ASN=$(grep "^router bgp" ${RUNNING_CONFIG} | awk '{ print $3 }')
   if [ -z "${ASN}" ]; then
      log_failure_msg "Failed to locate ASN of ${DAEMON}."
      exit 1
   fi
   declare -A GROUPING_CMDS=( ['route-map']='^route-map' ["router bgp ${ASN}"]='^router[[:blank:]]bgp[[:blank:]][[:digit:]]+$')
elif [ "x${DAEMON}" == "xripd" ]; then
   declare -A GROUPING_CMDS=( ['interface']='^interface' ['route-map']='^route-map' ['router rip']='^router[[:blank:]]rip$' )
elif [ "x${DAEMON}" == "xripngd" ]; then
   declare -A GROUPING_CMDS=( ['router ripng']='^router[[:blank:]]ripng$' )
elif [ "x${DAEMON}" == "xbabeld" ]; then
   declare -A GROUPING_CMDS=( ['router babel']='^router[[:blank:]]babel$' )
fi

declare -a ALL_NO_COMMAND_LIST=()
declare -a ALL_COMMAND_LIST=()

#
# retrieve lists of all available commands
#
for LIST in ROOT "${!GROUPING_CMDS[@]}"; do

   declare -a NO_COMMAND_LIST=()
   declare -a COMMAND_LIST=()

   #
   # uppest level commands
   #
   if [ "x${LIST}" == "xROOT" ]; then
      log_begin_msg "Retrieving global comands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'list' | sort)
      RETVAL=$?
   elif [ "x${LIST}" == "xinterface" ]; then
      log_begin_msg "Retrieving 'interface' comands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'interface XLBRXL' -c 'list' -c 'quit' -c 'no interface XLBRXL' | sort)
      RETVAL=$?
   elif [ "x${LIST}" == "xroute-map" ]; then
      log_begin_msg "Retrieving 'route-map' comands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'route-map XLBRXL permit 10' -c 'list' -c 'quit' -c 'no route-map XLBRXL permit 10' | sort)
      RETVAL=$?
   elif [[ "${LIST}" =~ ^router ]]; then
      log_begin_msg "Retrieving 'router' (${LIST}) comands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c ''"${LIST}"'' -c 'list' -c 'quit' | sort)
      RETVAL=$?
   else
      log_failure_msg "Unsupported list '${LIST}'. Exiting"
      exit 1
   fi

   if [ ${#COMMAND_LIST[@]} -le 1 ] || [ "${COMMAND_LIST[0]}" == "% Unknown command" ]; then
      log_failure_msg "an error occured!"
      exit 1
   fi

   if [ "x${RETVAL}" != "x0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi

   #
   # filter the COMMAND_LIST array, remove all non-configuration commands
   #
   for COMMAND_IDX in ${!COMMAND_LIST[@]}; do

      # remove leading blanks from command
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]##*( )}

      if [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*(no[[:blank:]])*(show|clear|debug|write|line|list|disable|enable|configure|copy|terminal|ping|traceroute|telnet|ssh|start-shell|undebug|dump|username|exit|end|table|password|mpls-te|quit|address-family|continue)[[:blank:]]* ]]; then
         unset COMMAND_LIST[COMMAND_IDX]
         continue
      fi

      if ! [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*no[[:blank:]] ]]; then

         # adapt the command to be used later as a pattern match
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\(+([[:graph:]])\)/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\{+([[:graph:]])\}/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//<+([[:graph:]])>/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D\/M/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X\/M/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//IFNAME/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//WORD/\([[:graph:]]+\)}
         continue
      fi

      #
      # transfer the "no" commands to their own array NO_COMMAND_LIST, and unset item from COMMAND_LIST array
      #

      # adapt the no-command and replace all possible parameters by word 'PARAM'
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\(+([[:graph:]])\)/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\{+([[:graph:]])\}/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//<+([[:graph:]])>/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D\/M/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X\/M/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//IFNAME/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//WORD/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//sequence-number/PARAM}
      NO_COMMAND_LIST[COMMAND_IDX]="${COMMAND_LIST[COMMAND_IDX]}"
      unset COMMAND_LIST[COMMAND_IDX]

   done

   log_end_msg "${#COMMAND_LIST[@]} commands found."

   # for each configuring command locate the matching unconfigure (no xxxx) command
   declare -a NO_MATCH_ARY=()
   declare -a MATCH_ARY=()
   log_begin_msg "Retrieving matching 'no' commands:"

   for COMMAND_IDX in ${!COMMAND_LIST[@]}; do

      ORIG_COMMAND="${COMMAND_LIST[COMMAND_IDX]}"

      # remove leading blanks from command
      COMMAND=${ORIG_COMMAND##*( )}

      # adapt the command to look like a bash pattern match
      #COMMAND=${COMMAND// /[[:blank:]]}
      #COMMAND=${COMMAND//\(+([[:graph:]])\)/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//\{+([[:graph:]])\}/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//<+([[:graph:]])>/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//A.B.C.D\/M/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//A.B.C.D/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//X:X::X:X\/M/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//X:X::X:X/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//IFNAME/\([[:graph:]]+\)}
      #COMMAND=${COMMAND//WORD/\([[:graph:]]+\)}

      #
      # get the first word of the command for quicker lookups in the 'no' comamnd list
      #
      COMMAND_WORD=${COMMAND%% *}

      if [ -z "${COMMAND_WORD}" ]; then
         log_failure_msg "Something is wrong, COMMAND_WORD should not be empty!"
         exit 1
      fi

      while [[ ! -z "${COMMAND// /}" ]]; do

         for NO_COMMAND_IDX in ${!NO_COMMAND_LIST[@]}; do

            NO_COMMAND="${NO_COMMAND_LIST[NO_COMMAND_IDX]}"

            # skip the no command if it does not start with the same first word. speeds up.
            if ! [[ "${NO_COMMAND}" =~ ^no[[:blank:]]*${COMMAND_WORD} ]]; then
               continue;
            fi

            # remove leading blanks from command
            #NO_COMMAND=${NO_COMMAND##*( )}

            # adapt the no-command and replace all possible parameters by word 'PARAM'
            #NO_COMMAND=${NO_COMMAND//\(+([[:graph:]])\)/PARAM}
            #NO_COMMAND=${NO_COMMAND//\{+([[:graph:]])\}/PARAM}
            #NO_COMMAND=${NO_COMMAND//<+([[:graph:]])>/PARAM}
            #NO_COMMAND=${NO_COMMAND//A.B.C.D\/M/PARAM}
            #NO_COMMAND=${NO_COMMAND//A.B.C.D/PARAM}
            #NO_COMMAND=${NO_COMMAND//X:X::X:X\/M/PARAM}
            #NO_COMMAND=${NO_COMMAND//X:X::X:X/PARAM}
            #NO_COMMAND=${NO_COMMAND//IFNAME/PARAM}
            #NO_COMMAND=${NO_COMMAND//WORD/PARAM}
            #NO_COMMAND=${NO_COMMAND//sequence-number/PARAM}

            while [[ ! -z "${NO_COMMAND// /}" ]]; do

               #
               # found a matching 'no' command?
               #
               if [ "${NO_COMMAND//PARAM/([[:graph:]]+)}" == "no ${COMMAND}" ]; then
                  # record the 'matching' command into the MATCH_ARY
                  MATCH_ARY+=( [${COMMAND_IDX}]="${COMMAND// /[[:blank:]]}" )
                  # record the 'no' matching command into the NO_MATCH_ARY
                  NO_MATCH_ARY+=( [${COMMAND_IDX}]="${NO_COMMAND}" )
                  # exit those loops and continue with the next command
                  #if [[ ${ORIG_COMMAND} =~ ip[[:blank:]]prefix ]]; then
                  #   #log_success_msg "For ${ORIG_COMMAND} i will use:"
                  #   #log_msg "${NO_COMMAND}"
                  #fi
                  #if [[ "${COMMAND}" =~ ^[[:blank:]]*ip[[:blank:]]prefix ]]; then
                  #   echo ${COMMAND}
                  #   echo ${NO_COMMAND}
                  #fi
                  continue 4
               fi

               #
               # strip the rightmost command parameter
               #
               NO_COMMAND=${NO_COMMAND% *}

               # if nothing has left, we break
               if [ "x${NO_COMMAND}" == "xno" ] || [ -z "${NO_COMMAND// /}" ]; then
                  break;
               fi
            done
         done

         #
         # strip the rightmost command option till we find a match
         #
         COMMAND=${COMMAND% *}

         # if nothing has left, we break
         if [ -z "${COMMAND// /}" ]; then
            break;
         fi

      done

      #
      # we come here only if no matching 'no' command has been found
      #
      log_failure_msg "Found no 'no' command for '${ORIG_COMMAND}' (list ${LIST})."
      log_failure_msg "I will better exit now for not doing something wrong!"
      exit 1
   done
   log_end_msg "${#NO_COMMAND_LIST[@]} commands found."

   if [ "x${#MATCH_ARY[@]}" == "x0" ]; then
      log_failure_msg "This is anomalous - found no commands for '${LIST}'! Better stopping."
      exit 1
   fi

   ALL_COMMAND_LIST+=$COMMAND_LIST
   ALL_NO_COMMAND_LIST=$NO_COMMAND_LIST
done

COMMAND_LIST=$ALL_COMMAND_LIST
NO_COMMAND_LIST=$ALL_NO_COMMAND_LIST

#
# walk through all grouping commands in ${RUNNING_CONFIG} and check if
# those commands have vanished from ${PRESTAGE_CONFIG}.
#
# if so, we need to issue a 'no' command to ${DAEMON} to remove that
# group first before continue checking for other commands.
#
log_msg "Checking for group commands that get removed."
for GROUP_CMD in "${!GROUPING_CMDS[@]}"; do

   #
   # get all grouping commands from ${RUNNING_CONFIG}
   #
   mapfile -t ENTRIES < <(grep -E "^${GROUP_CMD}" ${RUNNING_CONFIG})

   for ENTRY in "${ENTRIES[@]}"; do

      #
      # of group command will be no longer used in ${PRESTAGE_CONFIG},
      # issue a 'no' command for it.
      #
      if ! grep -qsE "^${ENTRY}" ${PRESTAGE_CONFIG}; then
         PRE_CMDS+=( "no ${ENTRY}" )
      fi

   done
done

#
# walk through all commands in ${RUNNING_CONFIG} and check if those
# commands have vanished in ${PRESTAGE_CONFIG}.
#
# if so, we need to remove them from an running ${DAEMON} instance
# by issueing "no ${CMD}".
#
declare -a REMOVE_CMDS=()

log_msg "Parsing running configuration."
mapfile -t ENTRIES < ${RUNNING_CONFIG}

for ENTRY_ID in "${!ENTRIES[@]}"; do

   # reset helper variables
   BGP_PEER_REMOVAL=
   NEIGHBOR=
   PEER_GROUP=

   #
   # ignore comment lines
   #
   if [[ "${ENTRIES[ENTRY_ID]}" =~ ^![[:blank:]]*[[:graph:]]+ ]]; then
      continue
   fi

   #
   # remove leading blanks from command
   #
   ENTRY=${ENTRIES[ENTRY_ID]##*( )}

   #
   # is a group-end indicate by a '!'-only-line?
   #
   if [ ! -z "${ENTERING_GROUP}" ] && [[ "${ENTRY}" =~ ^!$ ]]; then

      #
      # a special case for bgp - if a '!'-only-line is followed by a
      # 'address-family ipv6' line - we have to remain in that group
      # (router bgp XXXX) as now the IPv6 configuration will follow.
      #
      ((NEXT_ENTRY=ENTRY_ID+1))
      if ! [[ "${ENTRIES[NEXT_ENTRY]}" =~ ^[[:blank:]]*address-family[[:blank:]]ipv6$ ]]; then
         ENTERING_GROUP=
      fi

   fi

   for GROUP_CMD in "${!GROUPING_CMDS[@]}"; do

      #
      # if entry is a group command (which has been handled already a few lines
      # up) we can skip to the next command.
      #
      if ! [[ "${ENTRY}" =~ ^${GROUP_CMD} ]]; then
         continue;
      fi

      #
      # if we are still in a group that gets removed and it has not been cleanly
      # closed by a '!' line, add a '!' as separator to the REMOVE_CMD list.
      #
      if [ ! -z "${ENTERING_GROUP}" ]; then
         REMOVE_CMDS+=( '!' )
      fi

      ENTERING_GROUP=${ENTRY}
      ENTERED_GROUP=
      break
   done

   #
   # if command is a group command that is already scheduled for being removed,
   # we can skip it and all further entries of the group.
   #
   if [ ! -z "${ENTERING_GROUP}" ] && in_array PRE_CMDS "no ${ENTERING_GROUP}"; then
      continue;
   fi

   #
   # now we can ignore all comment-only ('!') lines.
   #
   if [[ "${ENTRY}" =~ ^!([[:blank:]]*) ]]; then
      unset ENTRIES[ENTRY_ID]
      continue;
   fi

   #
   # if the same command is still available in the ${PRESTAGE_CONFIG},
   # we can skip it - it doesn't get removed.
   #
   if grep -qsE "^(\s*)${ENTRY}$" ${PRESTAGE_CONFIG}; then
      unset ENTRIES[ENTRY_ID]
      continue;
   fi

   #
   # special case for access-lists and prefix-lists. if the list get's removed
   # we need to issue only a 'no' command with the lists name as parameter.
   #
   if [[ "${ENTRY}" =~ ^[[:blank:]]*ip[[:blank:]]access-list[[:blank:]]([[:graph:]]+)[[:blank:]] ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      if ! grep -qs "ip access-list ${LIST_NAME}" ${PRESTAGE_CONFIG}; then
         if ! in_array REMOVE_CMDS "no ip access-list ${LIST_NAME}"; then
            REMOVE_CMDS+=( "no ip access-list ${LIST_NAME}" )
         fi
         continue;
      fi
   elif [[ "${ENTRY}" =~ ^[[:blank:]]*ip[[:blank:]]prefix-list[[:blank:]]([[:graph:]]+)[[:blank:]] ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      if ! grep -qs "ip prefix-list ${LIST_NAME}" ${PRESTAGE_CONFIG}; then
         if ! in_array REMOVE_CMDS "no ip prefix-list ${LIST_NAME}"; then
            REMOVE_CMDS+=( "no ip prefix-list ${LIST_NAME}" )
         fi
         continue;
      fi
   fi

   #
   # special case for BGP - if neighbor already exists and has a peer-group or a
   # remote-as set, but now joins another peer-group - then that neighbor needs
   # to be deconfigured.
   #
   # has the neighbor currently a remote-as or peer-group defined.
   #
   if [[ "${ENTRY}" =~ ^[[:blank:]]*neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]remote-as[[:blank:]] ]] ||
      [[ "${ENTRY}" =~ ^[[:blank:]]*neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]peer-group[[:blank:]]([[:graph:]]+)$ ]]; then
      NEIGHBOR=${BASH_REMATCH[1]}
      test -z "${BASH_REMATCH[2]}" || PEER_GROUP=${BASH_REMATCH[2]}
      #
      # if the neighbor is currently _not_ member of a peer-group
      #
      if [ -z "${PEER_GROUP}" ]; then
         #echo "Handling remote-as for ${NEIGHBOR}"
         #
         # does PRESTAGE_CONFIG indicate neighbor will join a peer-group
         #
         if ! in_array ENTRIES "[[:blank:]]*neighbor[[:blank:]]${NEIGHBOR}[[:blank:]]peer-group[[:blank:]]" &&
            grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s" ${PRESTAGE_CONFIG}; then
            REMOVE_CMDS+=( "no neighbor ${NEIGHBOR}" )
         fi
      else
         #echo "Handling peer-group for ${NEIGHBOR}"
         #
         # does PRESTAGE_CONFIG indicate neighbor will join _another_ peer-group
         #
         if grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s" ${PRESTAGE_CONFIG}; then
            #echo "also in ${PRESTAGE_CONFIG} a peer-group is set!"
            if ! grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s${PEER_GROUP}\$" ${PRESTAGE_CONFIG}; then
               #echo "but it's another peergroup then ${PEER_GROUP}"
               REMOVE_CMDS+=( "no neighbor ${NEIGHBOR}" )
            fi
         fi
      fi
   fi

   #
   # if we are in a grouping-command (interface, router bgp, etc.) and the group
   # does _not_ get removed, we need to enter that group first before we can
   # modify one of its sub commands.
   #
   if [ ! -z "${ENTERING_GROUP}" ] && ! in_array PRE_CMDS "no ${ENTERING_GROUP}" && [ -z "${ENTERED_GROUP}" ]; then
      REMOVE_CMDS+=( "${ENTERING_GROUP}" )
      ENTERED_GROUP=${ENTERING_GROUP}
   #
   # special case for route-map - instead of trying to unset something wihtin
   # a route-map, unset the complete route-map instead. it's far easier to
   # handle.
   elif [ -z "${ENTERING_GROUP}" ] && [ ! -z "${ENTERED_GROUP}" ] &&
        [[ "${ENTERED_GROUP}" =~ ^[[:blank:]]*route-map[[:blank:]] ]]; then
      if ! in_array PRE_CMDS "no ${ENTERED_GROUP}"; then
         PRE_CMDS+=( "no ${ENTERED_GROUP}" )
      fi
   fi

   #
   # find the matching command
   #
   for MATCH_ID in ${!MATCH_ARY[@]}; do

      NO_COMMAND=
      MATCH_COMMAND="${MATCH_ARY[MATCH_ID]}"

      #
      # this usually should not happen...
      #
      if [ -z "${MATCH_COMMAND// /}" ]; then
         log_msg "${MATCH_COMMAND}"
         log_failure_msg "Found an empty match command at position ${MATCH_ID}!"
         exit 1
      fi

      #
      # skip to the next command if we have no match here.
      #
      if ! [[ "${ENTRY}" =~ ^${MATCH_COMMAND} ]]; then
         continue
      fi

      MATCH_NO_COMMAND="${NO_MATCH_ARY[MATCH_ID]}"

      #
      # this usually should not happen too...
      #
      if [ -z "${MATCH_NO_COMMAND// /}" ]; then
         log_msg "${MATCH_NO_COMMAND}"
         log_failure_msg "Found an empty match command at position ${MATCH_ID}!"
         exit 1
      fi

      #
      # if no parameter replacement is required for this command,
      # take it as it is and continue to the next command.
      #
      if ! [[ "${MATCH_NO_COMMAND}" =~ (PARAM)+ ]]; then
         REMOVE_CMDS+=( "${MATCH_NO_COMMAND}" )
         break
      fi

      # just to be sure...
      if [ ${#BASH_REMATCH[@]} -le 1 ]; then
         REMOVE_CMDS+=( "${MATCH_NO_COMMAND}" )
         break
      fi

      #
      # replace all 'PARAM' through their real values from ${ENTRY}.
      #
      NO_COMMAND=${MATCH_NO_COMMAND}

      # split no-command into words
      NO_COMMAND_PARAMS=( ${NO_COMMAND#no} )

      # split command into words
      ENTRY_PARAMS=( ${ENTRY} )

      for PARAM in ${!NO_COMMAND_PARAMS[@]}; do
         # skip the first array entry which is the full command
         if [ "x${PARAM}" == "x0" ] || [ "x${NO_COMMAND_PARAMS[PARAM]}" != "xPARAM" ]; then
            continue
         fi

         NO_COMMAND=${NO_COMMAND/PARAM/${ENTRY_PARAMS[PARAM]}}
      done

      #
      # special case for BGP - if a a neighbor gets removed by either
      #    - no neighbor name peer-group bla
      #    or
      #    - no neighbor name remote-as XXX
      # no further 'no's shall be invoked on that neighbor
      #
      if [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]peer-group ]] || \
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]remote-as[[:blank:]][[:digit:]]+$ ]] || \
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)$ ]]; then
         BGP_PEER_REMOVAL=${BASH_REMATCH[1]}
         if ! in_array REMOVE_CMDS "no neighbor ${BGP_PEER_REMOVAL}"; then
            REMOVE_CMDS+=( "no neighbor ${BGP_PEER_REMOVAL}" )
         fi
         break
      fi

      #
      # special case for BGP - if its a neighbor-command and the peer is getting
      # removed (because it's current hold in BGP_PEER_REMOVAL variable) we issue
      # are not going to issue another removal-command for that neighbor
      #
      if [ ! -z "${BGP_PEER_REMOVAL}" ] &&
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]${BGP_PEER_REMOVAL} ]]; then
         break
      fi

      # distance bgp ([0-9]*) ([0-9]*) ([0-9]*) - a special case within a router-bgp.
      # best removed by issuing "no distance bgp" ignoring all suffix-parameters
      if [[ "${ENTRY}" =~ ^[[:blank:]]*distance[[:blank:]]bgp ]]; then
         VTY_CALL+=" -c 'no distance bgp'"
         break;
      fi

      #echo "Entry: ${ENTRY}"
      #echo "Best match: ${MATCH_COMMAND}"
      #echo "No command: ${MATCH_NO_COMMAND}"
      #echo "Will use: ${NO_COMMAND}"
      #exit 5

      REMOVE_CMDS+=( "${NO_COMMAND}" )
      break
   done

   #if [[ "${ENTRY}" =~ shutdown ]]; then
   #   echo $ENTRY
   #   echo $NO_COMMAND
   #fi
done

#
# some time may have been gone while we were parsing -
# so check if the ${DAEMON} is still running right now.
#
if ! pgrep ${DAEMON} >/dev/null; then
   log_failure_msg "I'm already far on my way and suddendly ${DAEMON} is no longer active!?"
   log_failure_msg "What's going on here!? I'm stopping right now."
   exit 1
fi

if [ "x${DEBUG}" == "xtrue" ]; then
   echo; echo; echo
fi

#####
##### DEBUG OUTPUT
#####
#if [ "x${DEBUG}" == "xtrue" ]; then
#   if [ ${#PRE_CMDS[@]} -gt 0 ]; then
#      for PRE_CMD in "${PRE_CMDS[@]}"; do
#         echo "pre-cmd: ${PRE_CMD}"
#      done
#   fi
#   if [ ${#REMOVE_CMDS[@]} -gt 0 ]; then
#      for REM_CMD in "${REMOVE_CMDS[@]}"; do
#         echo "rem-cmd: ${REM_CMD}"
#      done
#   fi
#   if [ ${#NEW_CMDS[@]} -gt 0 ]; then
#      for NEW_CMD in "${NEW_CMDS[@]}"; do
#         echo "exc-cmd: ${NEW_CMD}"
#      done
#   fi
#fi
#exit 1

#
# execute all commands prior loading the new configuration
#
if [ ${#PRE_CMDS[@]} -gt 0 ]; then
   VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
   for PRE_CMD in "${PRE_CMDS[@]}"; do
      VTY_CALL+=" -c '${PRE_CMD}'"
   done
   log_msg "PRE_CMD"
   eval ${VTY_CALL}
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
   ${VTYSH} -d ${DAEMON} -c "write" 2>&1 >/dev/null
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
fi

if [ ${#REMOVE_CMDS[@]} -gt 0 ]; then
   VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
   for REM_CMD in "${REMOVE_CMDS[@]}"; do
      VTY_CALL+=" -c '${REM_CMD}'"
   done
   log_msg "REMOVE_CMD"
   eval ${VTY_CALL}
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
   ${VTYSH} -d ${DAEMON} -c "write" 2>&1 >/dev/null
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
fi

#
# load the new running configuration
#
VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
mapfile -t ENTRIES < ${PRESTAGE_CONFIG}
mapfile -t RUNNING_ENTRIES <${RUNNING_CONFIG}

declare -a VTY_OPTS=()

ENTERED_GROUP=
for ENTRY in "${ENTRIES[@]}"; do

   #
   # ignore comment lines
   #
   if [[ "${ENTRY}" =~ ^![[:blank:]]*[[:graph:]]+ ]]; then
      continue
   fi

   #
   # remove leading blanks from command
   #
   ENTRY=${ENTRY##*( )}

   #
   # is a group-end indicate by a '!'-only-line?
   #
   if [ ! -z "${ENTERED_GROUP}" ] && [[ "${ENTRY}" =~ ^!$ ]]; then

      #
      # a special case for bgp - if a '!'-only-line is followed by a
      # 'address-family ipv6' line - we have to remain in that group
      # (router bgp XXXX) as now the IPv6 configuration will follow.
      #
      ((NEXT_ENTRY=ENTRY_ID+1))
      if ! [[ "${ENTRIES[NEXT_ENTRY]}" =~ ^[[:blank:]]*address-family[[:blank:]]ipv6$ ]]; then
         VTY_OPTS+=( " -c 'exit'" )
         ENTERED_GROUP=
      fi
   fi

   # funilly the 'banner' command is not available with vtysh. skip it. a quagga bug
   [[ "${ENTRY}" =~ ^banner ]] && continue

   # if an 'interface', rember the interface we are currently working on for later entries
   if [[ "${ENTRY}" =~ ^[[:blank:]]*interface[[:blank:]]([[:graph:]]+)$ ]]; then
      IF_NAME=${BASH_REMATCH[1]}
   fi

   #
   # if the same entry is still present in the running configuration,
   # it's not required to reissue it. with bgpd that could lead to
   # BGP sessions getting restarted then.
   # but skip it only if command isn't a grouping-command (router bgp,
   # route-map, etc.).
   #
   for GROUP_CMD in ${GROUPING_CMDS[@]}; do
      if [[ "${ENTRY}" =~ ${GROUP_CMD} ]]; then
         #
         # if we are still in a group that gets removed and it has not been cleanly
         # closed by a '!' line, add a '!' as separator to the REMOVE_CMD list.
         #
         if [ ! -z "${ENTERED_GROUP}" ]; then
            VTY_OPTS+=( " -c 'exit'" )
         fi

         #
         # if the previous group does not contain any commands, we can unset it
         #
         if [ ${#VTY_OPTS[@]} -ge 2 ]; then
            for SUB_GROUP_CMD in ${GROUPING_CMDS[@]}; do
               PREV2_CMD=${VTY_OPTS[-2]# -c \'}
               PREV2_CMD=${PREV2_CMD%\'}
               if [ "${VTY_OPTS[-1]}" == " -c 'exit'" ] && [[ "${PREV2_CMD}" =~ ${SUB_GROUP_CMD} ]]; then
                  unset VTY_OPTS[${#VTY_OPTS[@]}-1]
                  unset VTY_OPTS[${#VTY_OPTS[@]}-1]
                  break
               fi
            done
         fi
         ENTERED_GROUP=${ENTRY}
         VTY_OPTS+=( " -c '${ENTRY}'" )
         continue 2;
      fi
   done
   if in_array RUNNING_ENTRIES "${ENTRY}"; then
      continue
   fi

   # ip ospf message-digest-key - a special case, command can not be in the
   # running configuration. it needs to be 'no'ed first if it already exists
   # in the running config!
   if [[ "${ENTRY}" =~ ^[[:blank:]]*ip[[:blank:]]ospf[[:blank:]]message-digest-key[[:blank:]]([[:digit:]]{1,3})[[:blank:]] ]]; then
      OSPF_MSG_KEY=${BASH_REMATCH[1]}
      if grep -Pzoqs "interface ${IF_NAME}\n(\s*)ip ospf message-digest-key ${OSPF_MSG_KEY}" ${RUNNING_CONFIG}; then
         VTY_OPTS+=( " -c 'no ip ospf message-digest-key ${OSPF_MSG_KEY}'" )
      fi
   fi

   VTY_OPTS+=( " -c '${ENTRY}'" )
done

log_msg "LOADING"
eval ${VTY_CALL} ${VTY_OPTS[@]}
if [ "$?" != "0" ]; then
   log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
   exit 1
fi

${VTYSH} -d ${DAEMON} -c "write" 2>&1 >/dev/null
if [ "$?" != "0" ]; then
   log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
   exit 1
fi

if [ "x${DAEMON}" == "xbgpd" ]; then
   ${VTYSH} -d ${DAEMON} -c 'clear ip bgp * soft' 2>&1 >/dev/null
   if [ "$?" != "0" ]; then
      log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
      exit 1
   fi
fi
