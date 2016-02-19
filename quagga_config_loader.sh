#!/bin/bash

#
# This file is part of quagga-config-loader.
# https://github.com/unki/quagga-config-loader
#
# quagga-config-loader, a configuration incubator for Quagga.
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
readonly RUNNING_CONFIG=${QUAGGA_CONF_DIR}/${DAEMON_CONFIG}
readonly PUPPET_CONFIG=${QUAGGA_CONF_DIR}/${DAEMON_CONFIG}.puppet
readonly PRESTAGE_CONFIG=${QUAGGA_CONF_DIR}/${DAEMON_CONFIG}.prestage

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
   unset -v 'OUTPUT'

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
      unset -v 'OSPF_AREA_PW'
   fi
fi

#
# check if actions have actually to be taken
#
if [ -e ${RUNNING_CONFIG} ]; then
   if diff --ignore-matching-lines='^!' ${RUNNING_CONFIG} ${PRESTAGE_CONFIG} >/dev/null; then
      # running config matches puppet generated config, no action required
      if [ "x${DEBUG}" == "xtrue" ]; then
         log_msg "Running-configuration (${RUNNING_CONFIG}) matches prestage-configuration (${PRESTAGE_CONFIG})."
         log_msg "No action required. Exiting."
      fi
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
# the easy part - if ${DAEMON} isn't running, we just go ahead and
# replace the ${RUNNING_CONFIG} with ${PRESTAGE_CONFIG} and exit.
#
if ! pgrep ${DAEMON} >/dev/null; then
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      log_msg cp ${PRESTAGE_CONFIG} ${RUNNING_CONFIG}
      exit 0
   fi
   [ -e ${RUNNING_CONFIG} ] && rm ${RUNNING_CONFIG}
   cp ${PRESTAGE_CONFIG} ${RUNNING_CONFIG}
   chown quagga.quagga ${RUNNING_CONFIG}
   chmod 640 ${RUNNING_CONFIG}
   exit 0
fi

################
#
# the harder part, act ${DAEMON} specific.
#  - unload vanished configuration lines
#  - load new configuration lines
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
   #
   # special case for bgpd, we need to grep out the AS number from that command
   #
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

declare -a NO_MATCH_ARY=()
declare -a MATCH_ARY=()

#
# retrieve lists of all available commands
#
ID_COUNTER=0
for LIST in ROOT "${!GROUPING_CMDS[@]}"; do

   declare -a NO_COMMAND_LIST=()
   declare -a COMMAND_LIST=()

   #
   # uppest level commands
   #
   if [ "x${LIST}" == "xROOT" ]; then
      log_begin_msg "Retrieving global commands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'list' | sort)
      RETVAL=$?
   elif [ "x${LIST}" == "xinterface" ]; then
      log_begin_msg "Retrieving 'interface' commands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'interface XLBRXL' -c 'list' -c 'quit' -c 'no interface XLBRXL' | sort)
      RETVAL=$?
   elif [ "x${LIST}" == "xroute-map" ]; then
      log_begin_msg "Retrieving 'route-map' commands:"
      mapfile -t COMMAND_LIST < <(${VTYSH} -d ${DAEMON} -c 'configure terminal' -c 'route-map XLBRXL permit 10' -c 'list' -c 'quit' -c 'no route-map XLBRXL permit 10' | sort)
      RETVAL=$?
   elif [[ "${LIST}" =~ ^router ]]; then
      log_begin_msg "Retrieving 'router' (${LIST}) commands:"
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

      #
      # ignore certain commands
      #
      if [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*(no[[:blank:]])*(show|clear|debug|write|line|list|disable|enable|configure|copy|terminal|ping|traceroute|telnet|ssh|start-shell|undebug|dump|username|exit|end|table|password|mpls-te|quit|address-family|continue)[[:blank:]]* ]]; then
         unset -v 'COMMAND_LIST[COMMAND_IDX]'
         continue
      fi

      #
      # other borked syntaxis we do not want to care about...
      #
      if [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*(no[[:blank:]])*access-list[[:print:]]+[[:blank:]]host[[:blank:]] ]] ||
         [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*(no[[:blank:]])*access-list[[:print:]]+[[:blank:]]ip[[:blank:]] ]] ||
         [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*(no[[:blank:]])*access-list[[:print:]]+[[:blank:]]exact-match$ ]]; then
         unset -v 'COMMAND_LIST[COMMAND_IDX]'
         continue
      fi

      if ! [[ "${COMMAND_LIST[COMMAND_IDX]}" =~ ^[[:blank:]]*no[[:blank:]] ]]; then
         # adapt the command to be used later as a pattern match
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\(+([[:graph:]])\)/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\{+([[:graph:]])\}/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//*(.)<+([[:graph:]])>/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D\/M/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X\/M/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//IFNAME/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//WORD/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\.LINE/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//LINE/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//sequence-number/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//PROTO/\([[:graph:]]+\)}
         COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//FILENAME/\([[:graph:]]+\)}
         continue
      fi

      #
      # transfer the "no" commands to their own array NO_COMMAND_LIST, and unset item from COMMAND_LIST array
      #

      # adapt the no-command and replace all possible parameters by word 'PARAM'
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\(+([[:graph:]])\)/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\{+([[:graph:]])\}/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//*(.)<+([[:graph:]])>/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D\/M/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//A.B.C.D/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X\/M/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//X:X::X:X/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//IFNAME/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//WORD/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//\.LINE/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//LINE/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//sequence-number/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//PROTO/PARAM}
      COMMAND_LIST[COMMAND_IDX]=${COMMAND_LIST[COMMAND_IDX]//FILENAME/PARAM}
      NO_COMMAND_LIST[COMMAND_IDX]="${COMMAND_LIST[COMMAND_IDX]}"
      unset -v 'COMMAND_LIST[COMMAND_IDX]'

   done

   log_end_msg "${#COMMAND_LIST[@]} commands found."

   # for each configuring command locate the matching unconfigure (no xxxx) command
   log_begin_msg "Retrieving matching 'no' commands:"

   for COMMAND_IDX in ${!COMMAND_LIST[@]}; do

      ORIG_COMMAND="${COMMAND_LIST[COMMAND_IDX]}"

      # remove leading blanks from command
      COMMAND=${ORIG_COMMAND##*( )}

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

            while [[ ! -z "${NO_COMMAND// /}" ]]; do

               #
               # found a matching 'no' command?
               #
               #if [[ "${NO_COMMAND//PARAM/([[:graph:]]+)}" =~ ^no[[:blank:]]*${COMMAND// /[[:blank:]]}$ ]]; then
               if [[ "no ${COMMAND}" =~ ^${NO_COMMAND//PARAM/([[:graph:]]+)}$ ]]; then
                  # record the 'matching' command into the MATCH_ARY
                  #MATCH_ARY+=( [${COMMAND_IDX}]="${COMMAND// /[[:blank:]]}" )
                  #echo "${MATCH_ARY[@]}"
                  MATCH_ARY+=( [${ID_COUNTER}]="${COMMAND// /[[:blank:]]}" )
                  # record the 'no' matching command into the NO_MATCH_ARY
                  #NO_MATCH_ARY+=( [${COMMAND_IDX}]="${NO_COMMAND}" )
                  NO_MATCH_ARY+=( [${ID_COUNTER}]="${NO_COMMAND}" )
                  #if [[ ${ORIG_COMMAND} =~ ip[[:blank:]]prefix ]]; then
                  #   log_success_msg "For ${ORIG_COMMAND} i will use:"
                  #   log_msg "${NO_COMMAND}"
                  #fi
                  #if [[ ${ORIG_COMMAND} =~ protocol ]]; then
                  #   log_success_msg "For ${ORIG_COMMAND} i will use:"
                  #   log_msg "no command::: ${NO_COMMAND}"
                  #   echo "COMMAND: ${COMMAND}"
                  #fi
                  #if [[ "${COMMAND}" =~ ^[[:blank:]]*ip[[:blank:]]prefix ]]; then
                  #   echo ${COMMAND}
                  #   echo ${NO_COMMAND}
                  #fi
                  # exit those loops and continue with the next command
                  ((ID_COUNTER++))
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

done

#
# sort match-array from the longest matches to the shortest.
#
mapfile -t SORTED_MATCH_KEYS < <(for MATCH_ID in ${!MATCH_ARY[@]}; do
   echo "${#MATCH_ARY[MATCH_ID]}#${MATCH_ID}"
done | sort -rn -t'#' -k1 | cut -d'#' -f2- --output-delimiter='=')

if [ -z "${SORTED_MATCH_KEYS}" ]; then
   log_failure_msg "Something must have gone wrong during sorting match-array!"
   exit 1
fi

declare -a MATCH_KEYS=()
for MATCH in "${SORTED_MATCH_KEYS[@]}"; do
   KEY=${MATCH%=*}
   VALUE=${MATCH##*=}
   if [ -z "${KEY}" ] || [ -z "${VALUE}" ]; then
      continue
   fi
   MATCH_KEYS+=( "${KEY}" )
done

#for MATCH in "${MATCH_KEYS[@]}"; do
#   echo "${MATCH}"
#done

#
# walk through all grouping commands in ${RUNNING_CONFIG} and check if
# those commands have vanished from ${PRESTAGE_CONFIG}.
#
# if so, we need to issue a 'no' command to ${DAEMON} to remove that
# group first before continue checking for other commands.
#
log_begin_msg "Checking for group commands that get removed:"
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
log_end_msg "${#PRE_CMDS[@]} scheduled for removal."

#
# walk through all commands in ${RUNNING_CONFIG} and check if those
# commands have vanished in ${PRESTAGE_CONFIG}.
#
# if so, we need to remove them from an running ${DAEMON} instance
# by issueing "no ${CMD}".
#
declare -a REMOVE_CMDS=()

log_begin_msg "Parsing running configuration:"
mapfile -t ENTRIES < ${RUNNING_CONFIG}
log_end_msg "${#ENTRIES[@]} entries."

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

   # we currently can not revert existing "no"-commands like
   #     no neighbor dmz-routers send-community both
   # that are present int running configuration
   if [[ "${ENTRY}" =~ ^[[:blank:]]*no[[:blank:]] ]]; then
      continue
   fi

   #
   # is a group-end indicate by a '!'-only-line?
   #
   if [ ! -z "${ENTERING_GROUP}" ] && [[ "${ENTRY}" =~ ^!$ ]]; then

      #
      # a special case for bgpd - if a '!'-only-line is followed by a
      # 'address-family ipv6' line - we have to remain in that group
      # (router bgp XXXX) as now the IPv6 configuration will follow.
      #
      ((NEXT_ENTRY=ENTRY_ID+1))
      if ! [[ "${ENTRIES[NEXT_ENTRY]}" =~ ^[[:blank:]]*address-family[[:blank:]]ipv6$ ]]; then
         ENTERING_GROUP=
         unset -v "GROUP_SECTION_PRESTAGE_CONFIG"
         unset -v "GROUP_ARY"
         #
         # if the last command that has been pushed to NEW_CMDS is exactly
         # our ENTERED_GROUP, we can remove it from the NEW_CMDS array
         #
         if [ ${#REMOVE_CMDS[@]} -gt 0 ] &&
            [ ! -z "${REMOVE_CMDS[-1]}" ] &&
            [[ ${REMOVE_CMDS[-1]} =~ ^${ENTERED_GROUP// /[[:blank:]]}$ ]]; then
            # unset of array elements by using an negative array index seems not to be supported right now.
            #unset -v 'REMOVE_CMDS[-1]'
            LAST_ELEMENT="$(( ${#REMOVE_CMDS[@]} - 1 ))"
            unset -v "REMOVE_CMDS[${LAST_ELEMENT}]"
         fi
      fi
   fi

   for GROUP_CMD in "${!GROUPING_CMDS[@]}"; do

      #
      # if entry is a group command we can continue here.
      # would that group be removed, it will be already done in PRE_CMDS
      #
      if ! [[ "${ENTRY}" =~ ^${GROUP_CMD} ]]; then
         continue;
      fi

      #
      # if we have just handled a group before and that group has not been
      # cleanly closed by a '!' line, add a '!' as separator to the REMOVE_CMDS
      # list.
      #
      if [ ! -z "${ENTERING_GROUP}" ]; then
         REMOVE_CMDS+=( '!' )
      fi

      # helper-variable to remember that we have found a grouping-cmd
      ENTERING_GROUP=${ENTRY}
      ENTERED_GROUP=

      if grep -qsF "${ENTERING_GROUP}" ${PRESTAGE_CONFIG}; then
         #
         # retrieve the prestage group stance via awk
         #
         GROUP_SECTION_PRESTAGE_CONFIG=$(awk "/^${ENTERING_GROUP}/,/\!/" ${PRESTAGE_CONFIG})
         if [ -z "${GROUP_SECTION_PRESTAGE_CONFIG}" ]; then
            log_failure_msg "awk returned no group-section for group ${ENTERING_GROUP} (${PRESTAGE_CONFIG})!"
            exit 1
         fi
         unset -v 'GROUP_ARY'
         mapfile -t GROUP_ARY <<<"${GROUP_SECTION_PRESTAGE_CONFIG}"
      fi
      break
   done

   #
   # if command is a group command that is already scheduled for being removed,
   # we can move on and skip all further commands from that group.
   #
   if [ ! -z "${ENTERING_GROUP}" ] && in_array PRE_CMDS ^no[[:blank:]]${ENTERING_GROUP// /[[:blank:]]}$; then
      unset -v 'ENTRIES[ENTRY_ID]'
      continue;
   fi

   #
   # now we can ignore all comment-only ('!') lines.
   #
   if [[ "${ENTRY}" =~ ^!([[:blank:]]*) ]]; then
      unset -v 'ENTRIES[ENTRY_ID]'
      continue;
   fi

   # if an 'interface', rember the interface we are currently working on for later entries
   if [[ "${ENTRY}" =~ ^[[:blank:]]*interface[[:blank:]]([[:graph:]]+)$ ]]; then
      IF_NAME=${BASH_REMATCH[1]}
   fi

   #
   # if the exactly same command (-F option for grep is important!)
   # is still present in ${PRESTAGE_CONFIG}, we can skip it. line
   # will not get removed.
   #
   if [ ! -z "${ENTERING_GROUP}" ] && in_array GROUP_ARY ^[[:blank:]]*${ENTRY// /[[:blank:]]}$; then
      continue
   elif [ -z "${ENTERING_GROUP}" ] && grep -qsF "${ENTRY}" ${PRESTAGE_CONFIG}; then
      continue
   fi

   #
   # special cases for access-, prefix-and as-path-lists.
   #
   # if the list gets completely removed, we need to issue only
   # a 'no' command with the lists name as parameter.
   #
   if [[ "${ENTRY}" =~ ^[[:blank:]]*access-list[[:blank:]]([[:graph:]]+)[[:blank:]] ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      if ! grep -qsE "^[[:blank:]]*access-list[[:blank:]]${LIST_NAME}" ${PRESTAGE_CONFIG}; then
         if ! in_array REMOVE_CMDS ^no[[:blank:]]access-list[[:blank:]]${LIST_NAME}$; then
            REMOVE_CMDS+=( "no access-list ${LIST_NAME}" )
         fi
         continue;
      fi
   elif [[ "${ENTRY}" =~ ^[[:blank:]]*ip[[:blank:]]prefix-list[[:blank:]]([[:graph:]]+)[[:blank:]] ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      if ! grep -qsE "^[[:blank:]]*ip[[:blank:]]prefix-list[[:blank:]]${LIST_NAME}" ${PRESTAGE_CONFIG}; then
         if ! in_array REMOVE_CMDS ^no[[:blank:]]ip[[:blank:]]prefix-list[[:blank:]]${LIST_NAME}$; then
            REMOVE_CMDS+=( "no ip prefix-list ${LIST_NAME}" )
         fi
         continue;
      fi
   elif [[ "${ENTRY}" =~ ^[[:blank:]]*ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]([[:graph:]]+)[[:blank:]] ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      if ! grep -qsE "^[[:blank:]]*ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]${LIST_NAME}" ${PRESTAGE_CONFIG}; then
         if ! in_array REMOVE_CMDS ^no[[:blank:]]ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]${LIST_NAME}$; then
            REMOVE_CMDS+=( "no ip as-path access-list ${LIST_NAME}" )
         fi
         continue;
      fi
   fi

   #
   # special case for bgpd - if neighbor already exists and has a peer-group or a
   # remote-as set, but now joins another peer-group - then that neighbor needs
   # to be deconfigured first.
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
         #
         # does PRESTAGE_CONFIG indicate neighbor wasn't in a peer-group before
         # and will now join a peer-group
         #
         if ! in_array ENTRIES ^[[:blank:]]*neighbor[[:blank:]]${NEIGHBOR}[[:blank:]]peer-group[[:blank:]] &&
            grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s" ${PRESTAGE_CONFIG}; then
            REMOVE_CMDS+=( "${ENTERING_GROUP}" )
            REMOVE_CMDS+=( "no neighbor ${NEIGHBOR}" )
            REMOVE_CMDS+=( "!" )
         fi
      else
         #
         # does PRESTAGE_CONFIG indicate neighbor is already in a peer-group and will
         # now move on to _another_ peer-group
         #
         if grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s" ${PRESTAGE_CONFIG}; then
            if ! grep -qsE "^(\s*)neighbor\s${NEIGHBOR}\speer-group\s${PEER_GROUP}\$" ${PRESTAGE_CONFIG}; then
               REMOVE_CMDS+=( "${ENTERING_GROUP}" )
               REMOVE_CMDS+=( "no neighbor ${NEIGHBOR}" )
               REMOVE_CMDS+=( "!" )
            fi
         fi
      fi
   fi

   #
   # if we are in a grouping-command (interface, router bgp, etc.) and the group
   # does _not_ get removed, we need to enter that group first before we can add
   # or modify one of its sub commands.
   #
   if [ ! -z "${ENTERING_GROUP}" ] &&
      [ -z "${ENTERED_GROUP}" ] &&
      ! in_array PRE_CMDS ^no[[:blank:]]${ENTERING_GROUP// /[[:blank:]]}$; then
      REMOVE_CMDS+=( "${ENTERING_GROUP}" )
      ENTERED_GROUP=${ENTERING_GROUP}
   fi
   #
   # special case for route-map - instead of trying to unset something within
   # a route-map, unset the complete route-map instead.
   # it is far easier to handle that way.
   #
   #elif [ -z "${ENTERING_GROUP}" ] && [ ! -z "${ENTERED_GROUP}" ] &&
   #     [[ "${ENTERED_GROUP}" =~ ^[[:blank:]]*route-map[[:blank:]] ]]; then
   #   if ! in_array PRE_CMDS ^no[[:blank:]]${ENTERED_GROUP// /[[:blank:]]}$; then
   #      PRE_CMDS+=( "no ${ENTERED_GROUP}" )
   #   fi

   #
   # special case for route-maps in bgpd for set-ip-next­hop-peer-address.
   # how to remove that command is not stated in the command-'list'.
   # so we have to hardcode it here.
   #
   if [[ "${ENTRY}" =~ ^[[:blank:]]*set[[:blank:]]ip[[:blank:]]next-hop[[:blank:]]peer-address$ ]]; then
      REMOVE_CMDS+=( "no set ip next-hop" )
      continue
   fi

   #
   # now let us find the matching command for the
   # current processed entry.
   #
   #for MATCH_ID in ${!MATCH_ARY[@]}; do
   for MATCH_ID in ${MATCH_KEYS[@]}; do

      NO_COMMAND=
      MATCH_COMMAND="${MATCH_ARY[${MATCH_ID}]}"

      #
      # this usually should not happen...
      #
      if [ -z "${MATCH_COMMAND// /}" ]; then
         log_msg "${MATCH_COMMAND}"
         log_failure_msg "Found an empty match command at position ${MATCH_ID}!"
         exit 1
      fi

      # passwords - strangly there is no "no password" command in Quagga.
      # so we are not trying to unset an existing password line.
      if [[ "${ENTRY}" =~ ^[[:blank:]]*password[[:blank:]] ]]; then
         NO_COMMAND=true
         break;
      fi

      #
      # skip to the next command if we have no match here.
      #
      # enable for debugging
      #if [[ "${ENTRY}" =~ protocol ]]; then
      #   echo ${ENTRY}
      #   echo ${MATCH_COMMAND}
      #fi
      if ! [[ "${ENTRY}" =~ ^${MATCH_COMMAND} ]]; then
         continue
      fi

      MATCH_NO_COMMAND="${NO_MATCH_ARY[${MATCH_ID}]}"

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
         NO_COMMAND=true
         break
      fi

      # just to be sure...
      if [ ${#BASH_REMATCH[@]} -le 1 ]; then
         REMOVE_CMDS+=( "${MATCH_NO_COMMAND}" )
         NO_COMMAND=true
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
      # special case for bgpd - if a neighbor gets removed by either
      #    - no neighbor name peer-group bla
      #    or
      #    - no neighbor name remote-as XXX
      # no further 'no's shall be invoked on that neighbor
      #
      if [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]peer-group ]] || \
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)[[:blank:]]remote-as[[:blank:]][[:digit:]]+$ ]] || \
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]([[:graph:]]+)$ ]]; then
         BGP_PEER_REMOVAL=${BASH_REMATCH[1]}
         if ! in_array REMOVE_CMDS ^no[[:blank:]]neighbor[[:blank:]]${BGP_PEER_REMOVAL}$; then
            REMOVE_CMDS+=( "no neighbor ${BGP_PEER_REMOVAL}" )
         fi
         NO_COMMAND=true
         break
      fi

      #
      # special case for bgpd - if its a neighbor-command and the peer is getting
      # removed (because it's current hold in BGP_PEER_REMOVAL variable) we are
      # not going to issue another removal-command for that neighbor
      #
      if [ ! -z "${BGP_PEER_REMOVAL}" ] &&
         [[ "${NO_COMMAND}" =~ ^no[[:blank:]]neighbor[[:blank:]]${BGP_PEER_REMOVAL}[[:print:]]+$ ]]; then
         NO_COMMAND=true
         break
      fi

      #
      # special case for bgpd - if the BGP_IGNORE_NEIGHBOR_SHUTDOWN option is set
      # and a shutdown option for a neighbor would be removed, ignore that command.
      #
      if [ ! -z "${BGP_IGNORE_NEIGHBOR_SHUTDOWN}" ]; then
         if [[ "${NO_COMMAND}" =~ ^[[:blank:]]*no[[:blank:]]+neighbor[[:blank:]][[:graph:]]+[[:blank:]]shutdown$ ]]; then
            NO_COMMAND=true
            break
         fi
      fi

      # distance bgp ([0-9]*) ([0-9]*) ([0-9]*) - a special case for bgpd within
      # a router-bgp statement. best removed by issuing "no distance bgp"
      # ignoring all suffix-parameters
      if [[ "${ENTRY}" =~ ^[[:blank:]]*distance[[:blank:]]bgp ]]; then
         NO_COMMAND=true
         REMOVE_CMDS+=( "no distance bgp" )
         break;
      fi

      #
      # ip ospf message-digest-key - a special case ospfd, command can
      # not be overwriten in the running configuration (already-exists-
      # error). it needs to be 'no'ed first.
      #
      if [[ "${ENTRY}" =~ ^ip[[:blank:]]ospf[[:blank:]]message-digest-key[[:blank:]]([[:digit:]]{1,3})[[:blank:]] ]]; then
         OSPF_MSG_KEY=${BASH_REMATCH[1]}
         if grep -Pzoqs "interface ${IF_NAME}\n(\s*)ip ospf message-digest-key ${OSPF_MSG_KEY}\s" ${RUNNING_CONFIG}; then
            NO_COMMAND=true
            REMOVE_CMDS+=( "no ip ospf message-digest-key ${OSPF_MSG_KEY}" )
            break
         fi
      fi

      #echo "Entry: ${ENTRY}"
      ##echo "Best match: ${MATCH_COMMAND}"
      #echo "No command: ${MATCH_NO_COMMAND}"
      #echo "Will use: ${NO_COMMAND}"
      #exit 5

      REMOVE_CMDS+=( "${NO_COMMAND}" )
      NO_COMMAND=true
      break
   done

   #
   # we come here only if no matching 'no' command has been found
   #
   if [ -z ${NO_COMMAND} ]; then
      log_failure_msg "Found no 'no' command for '${ENTRY}'."
      log_failure_msg "I will better exit now for not doing something wrong!"
      exit 1
   fi
   #if [[ "${ENTRY}" =~ prepend ]]; then
   #   echo $ENTRY
   #   echo $NO_COMMAND
   #fi
done

# walk through all commands in ${PRESTAGE_CONFIG} and check if
# those are already in ${RUNNING_CONFIG}.
#
# if no, we need to issue those commands on ${DAEMON} instance.
#

log_begin_msg "Parsing prestage configuration:"
mapfile -t ENTRIES < ${PRESTAGE_CONFIG}
mapfile -t RUNNING_ENTRIES <${RUNNING_CONFIG}
log_end_msg "${#ENTRIES[@]} entries."

declare -a NEW_CMDS=()
declare -a GROUP_CMD_ARY=()
declare -a ACCESS_LIST_ARY=()
declare -a PREFIX_LIST_ARY=()

ENTERED_GROUP=
for ENTRY_ID in "${!ENTRIES[@]}"; do

   ENTRY=${ENTRIES[ENTRY_ID]}

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
      # a special case for bgpd - if a '!'-only-line is followed by a
      # 'address-family ipv6' line - we have to remain in that group
      # (router bgp XXXX) as now the IPv6 configuration will follow.
      #
      ((NEXT_ENTRY=ENTRY_ID+1))
      if ! [[ "${ENTRIES[NEXT_ENTRY]}" =~ ^[[:blank:]]*address-family[[:blank:]]ipv6$ ]]; then
         NEW_CMDS+=( "exit" )
         ENTERED_GROUP=
         unset -v "GROUP_SECTION_RUNNING_CONFIG"
         unset -v "GROUP_ARY"
         #
         # if the last command that has been pushed to NEW_CMDS is exactly
         # our ENTERED_GROUP, we can remove it from the NEW_CMDS array
         #
         if [ ${#NEW_CMDS[@]} -gt 0 ] &&
            [ ! -z "${NEW_CMDS[-1]}" ] &&
            [[ ${NEW_CMDS[-1]} =~ ^${ENTERED_GROUP// /[[:blank:]]}$ ]]; then
            # unset of array elements by using an negative array index seems not to be supported right now.
            #unset -v 'NEW_CMDS[-1]'
            LAST_ELEMENT="$(( ${#NEW_CMDS[@]} - 1 ))"
            unset -v "NEW_CMDS[${LAST_ELEMENT}]"
         fi
         continue
      fi
   fi

   # funilly the 'banner' command is not available by vtysh. skip it. a Quagga bug
   [[ "${ENTRY}" =~ ^banner ]] && continue

   # if an 'interface', rember the interface we are currently working on for later entries
   if [[ "${ENTRY}" =~ ^interface[[:blank:]]([[:graph:]]+)$ ]]; then
      IF_NAME=${BASH_REMATCH[1]}
   fi

   #
   # now we try to figure out, if the same entry is still present in the
   # running configuration.
   # If so, we do not need to reissue the same command on ${DAEMON}.
   #
   # What should be avoided in case of bgpd is to not reestablish BGP
   # session to peers. But there are some special chases to handle.
   #

   #
   # grouping-commands (router bgp, route-map, etc.) need special treating,
   # as it could be required to enter a group first to issue the following
   # command.
   #
   for GROUP_CMD in ${GROUPING_CMDS[@]}; do
      if [[ "${ENTRY}" =~ ${GROUP_CMD} ]]; then
         #
         # if we are still in a group that gets removed and it has not been cleanly
         # closed by a '!' line, add a '!' as separator to the REMOVE_CMD list.
         #
         if [ ! -z "${ENTERED_GROUP}" ]; then
            NEW_CMDS+=( "exit" )
         fi

         ENTERED_GROUP=${ENTRY}
         NEW_CMDS+=( "${ENTRY}" )

         if grep -qsF "${ENTERED_GROUP}" ${RUNNING_CONFIG}; then
            #
            # retrieve the group stance via awk
            #
            GROUP_SECTION_RUNNING_CONFIG=$(awk "/^${ENTERED_GROUP}/,/\!/" ${RUNNING_CONFIG})
            if [ -z "${GROUP_SECTION_RUNNING_CONFIG}" ]; then
               log_failure_msg "awk returned no group section for group ${ENTERED_GROUP} (${RUNNING_CONFIG})!"
               exit 1
            fi
            unset -v 'GROUP_ARY'
            mapfile -t GROUP_ARY <<<"${GROUP_SECTION_RUNNING_CONFIG}"
         fi
         continue 2;
      fi
   done

   #
   # if new items get added to prefix- or access-list.
   # - check if there is already a list-entry with the same sequence-number
   # - check if there is already a list-entry with the same IP/network-address
   # list and re-insert all items. so it's easier to guarantee the right order.
   #
   # comments we do not need to further consider
   if [[ "${ENTRY}" =~ ^(access-list)[[:blank:]]([[:graph:]]+)[[:blank:]]remark ]] ||
      [[ "${ENTRY}" =~ ^(ip[[:blank:]]prefix-list)[[:blank:]]([[:graph:]]+)[[:blank:]]description ]]; then
      LIST=${BASH_REMATCH[1]}
      LIST_NAME=${BASH_REMATCH[2]}
      # if the exactly same description command is present in running-configuration, do not touch it.
      if in_array RUNNING_ENTRIES ^${ENTRY// /[[:blank:]]}$; then
         continue;
      fi
      if ! in_array REMOVE_CMDS ^no[[:blank:]]${LIST}[[:blank:]]${LIST_NAME}$; then
         continue;
      fi
      NEW_CMDS+=( "${ENTRY}" )
      continue
   fi
   #
   # access-lists
   #
   if [[ "${ENTRY}" =~ ^access-list[[:blank:]]([[:graph:]]+)[[:blank:]]([[:graph:]]+)[[:blank:]]([[:graph:]])$ ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      LIST_MODE=${BASH_REMATCH[2]}
      LIST_TARGET=${BASH_REMATCH[3]}
      # if access-list is schedulded for removal, we can skip this line.
      if in_array REMOVE_CMDS ^no[[:blank:]]access-list[[:blank:]]${LIST_NAME}$; then
         continue;
      fi
      # if the exactly same command is present in running-configuration, do not touch it.
      if in_array RUNNING_ENTRIES ^[[:blank:]]*${ENTRY// /[[:blank:]]}$; then
         continue;
      fi
      for MODE in permit deny; do
         if in_array RUNNING_ENTRIES ^access-list[[:blank:]]${LIST_NAME}[[:blank:]]${MODE}[[:blank:]]${LIST_TARGET}; then
            REMOVE_CMDS+=( "no access-list ${LIST_NAME} ${MODE} ${LIST_TARGET}" )
         fi
      done
      NEW_CMDS+=( "${ENTRY}" )
      continue
   fi
   #
   # as-path access-lists
   #
   if [[ "${ENTRY}" =~ ^ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]([[:graph:]]+)[[:blank:]]([[:graph:]]+)[[:blank:]]([[:print:]]+)$ ]]; then
      LIST_NAME=${BASH_REMATCH[1]}
      LIST_MODE=${BASH_REMATCH[2]}
      LIST_TARGET=${BASH_REMATCH[3]}
      # as as-path can contain regular expression characters, we need to escape them
      ENTRY_ESCAPED=${ENTRY}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\|/\\|}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\*/\\*}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\./\\.}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\+/\\+}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\?/\\?}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\[/\\[}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\]/\\]}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\(/\\(}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\)/\\)}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\^/\\^}
      ENTRY_ESCAPED=${ENTRY_ESCAPED//\$/\\$}
      #echo; echo ${ENTRY}
      # if as-path access-list is schedulded for removal, we can skip this line.
      if in_array REMOVE_CMDS ^no[[:blank:]]ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]${LIST_NAME}$; then
         continue;
      fi
      # if the exactly same command is present in running-configuration, we can move on to the next entry.
      if in_array RUNNING_ENTRIES ^[[:blank:]]*${ENTRY_ESCAPED// /[[:blank:]]}$; then
         #echo "Existing entry: ${ENTRY_ESCAPED}"
         continue;
      fi
      for MODE in permit deny; do
         if in_array RUNNING_ENTRIES ^[[:blank:]]*ip[[:blank:]]as-path[[:blank:]]access-list[[:blank:]]${LIST_NAME}[[:blank:]]${MODE}[[:blank:]]${LIST_TARGET}$; then
            #echo "Removing entry: ${ENTRY_ESCAPED}"
            REMOVE_CMDS+=( "no ip as-path access-list ${LIST_NAME} ${MODE} ${LIST_TARGET}" )
         fi
      done
      #echo "New entry: ${ENTRY_ESCAPED}"
      NEW_CMDS+=( "${ENTRY}" )
      continue
   fi
   #
   # prefix-lists
   #
   if [[ "${ENTRY}" =~ ^ip[[:blank:]]prefix-list[[:blank:]]([[:graph:]]+)[[:blank:]]seq[[:blank:]]([[:digit:]]+)[[:blank:]]([[:graph:]]+)[[:blank:]]([[:graph:]]+)$ ]]; then
      #log_msg "got prefix-list: ${ENTRY}"
      LIST_NAME=${BASH_REMATCH[1]}
      LIST_SEQ=${BASH_REMATCH[2]}
      LIST_MODE=${BASH_REMATCH[3]}
      LIST_TARGET=${BASH_REMATCH[4]}
      #
      # if prefix-list is schedulded for removal, we can skip this line.
      #
      if in_array REMOVE_CMDS ^no[[:blank:]]*ip[[:blank:]]*prefix-list[[:blank:]]*${LIST_NAME}$; then
         #log_msg "already scheduled for removal"
         continue;
      fi
      #
      # if the exactly same command is present in running-configuration,
      # do not touch it.
      #
      if in_array RUNNING_ENTRIES ^[[:blank:]]*${ENTRY// /[[:blank:]]}$; then
         #log_msg "still exists in running: ${ENTRY}"
         continue;
      fi
      # normally commands can be overwritten when specifying a sequence-number. but do it cleaner for now.
      #if in_array RUNNING_ENTRIES ^ip[[:blank:]]prefix-list[[:blank:]]${LIST_NAME}[[:blank:]]seq[[:blank:]]${LIST_SEQ}; then
      #   #log_msg "will remove existing ${LIST_NAME} ${LIST_SEQ}"
      #   REMOVE_CMDS+=( "no ip prefix-list ${LIST_NAME} seq ${LIST_SEQ}" )
      #fi
      #
      # if there is already the same target in our prefix-list, but
      # possible at another position as the new one, unload it.
      #
      for MODE in permit deny; do
         if in_array RUNNING_ENTRIES ^ip[[:blank:]]prefix-list[[:blank:]]${LIST_NAME}[[:blank:]]seq[[:blank:]][[:digit:]]+[[:blank:]]${MODE}[[:blank:]]${LIST_TARGET}$; then
            #log_msg "will remove existing ${LIST_NAME} ${MODE} ${LIST_TARGET}"
            REMOVE_CMDS+=( "no ip prefix-list ${LIST_NAME} ${MODE} ${LIST_TARGET}" )
         fi
      done
      NEW_CMDS+=( "${ENTRY}" )
      continue
   fi

   #
   # if we are in a group, we need to figure out if running-config
   # contains the exactly same entry in the exactly same group.
   #
   if [ ! -z "${ENTERED_GROUP}" ]; then
      #
      # if group hasn't exist before, we can continue
      #
      if ! in_array RUNNING_ENTRIES ^[[:blank:]]*${ENTERED_GROUP// /[[:blank:]]}$; then
      #if ! grep -qsE "^(\s*)${ENTERED_GROUP}" ${RUNNING_CONFIG}; then
         NEW_CMDS+=( "${ENTRY}" )
         continue;
      fi

      #
      # if group has existed before, but has now been scheduled for
      # removal in the PRE_CMDs array (because one or more lines may
      # have vanished from that group), we have to reload that group anyway.
      #
      if in_array PRE_CMDS ^no[[:blank:]]${ENTERED_GROUP// /[[:blank:]]}$; then
         NEW_CMDS+=( "${ENTRY}" )
         continue;
      fi

      #
      # does the group section contain our $ENTRY
      #
      if ! in_array GROUP_ARY ^[[:blank:]]*${ENTRY// /[[:blank:]]}$; then
         NEW_CMDS+=( "${ENTRY}" )
         continue;
      fi
   fi
   # now finally.
   if in_array RUNNING_ENTRIES ^[[:blank:]]*${ENTRY// /[[:blank:]]}$; then
      continue
   fi

   #
   # from here we know that this entry needs be issued on ${DAEMON}
   #

   #
   # ip ospf message-digest-key - a special case ospfd, command can
   # not be overwriten in the running configuration (already-exists-
   # error). it needs to be 'no'ed first.
   #
   if [[ "${ENTRY}" =~ ^ip[[:blank:]]ospf[[:blank:]]message-digest-key[[:blank:]]([[:digit:]]{1,3})[[:blank:]] ]]; then
      OSPF_MSG_KEY=${BASH_REMATCH[1]}
      if grep -Pzoqs "interface ${IF_NAME}\n(\s*)ip ospf message-digest-key ${OSPF_MSG_KEY}" ${RUNNING_CONFIG}; then
         NEW_CMDS+=( "no ip ospf message-digest-key ${OSPF_MSG_KEY}" )
      fi
   fi

   NEW_CMDS+=( "${ENTRY}" )
done

#
# filter out empty group-statements from command list.
# this makes loading new commands beautifuler.
#
SKIP_NEXT=
if [ ${#NEW_CMDS[@]} -gt 0 ]; then
   for NEW_CMD_ID in "${!NEW_CMDS[@]}"; do
      if [ "x${SKIP_NEXT}" == "xtrue" ]; then
         SKIP_NEXT=
         unset -v 'NEW_CMDS[NEW_CMD_ID]'
         continue
      fi
      NEW_CMD=${NEW_CMDS[NEW_CMD_ID]}
      #
      # if the new command is just an empty group, skip it.
      #
      # this will lead to a string "CURRENT_COMMAND NEXT_COMMAND
      NEXT_COMMAND=${NEW_CMDS[@]:NEW_CMD_ID:2}
      for GROUP_CMD in ${GROUPING_CMDS[@]}; do
         if [[ "${NEW_CMD}" =~ ${GROUP_CMD} ]] && [[ "${NEXT_COMMAND}" =~ [[:blank:]]exit$ ]]; then
            SKIP_NEXT=true
            unset -v 'NEW_CMDS[NEW_CMD_ID]'
            continue 2;
         fi
      done
   done
fi

#
# some time may have been gone while we were parsing -
# so check if the ${DAEMON} is still running right now.
#
if ! pgrep ${DAEMON} >/dev/null; then
   log_failure_msg "I'm already far on my way and suddendly ${DAEMON} is no longer active!?"
   log_failure_msg "What's going on here!? I'm stopping right now."
   exit 1
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
CHANGES_MADE=
if [ ${#PRE_CMDS[@]} -gt 0 ]; then
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      echo
      log_msg "DRY-RUN: the following commands have been added to pre-commands list:"
   fi
   VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
   VTY_OPTS=
   for PRE_CMD in "${PRE_CMDS[@]}"; do
      if [ "x${DRY_RUN}" == "xtrue" ]; then
         log_msg "DRY-RUN: ${PRE_CMD}"
      fi
      VTY_OPTS+=" -c '${PRE_CMD}'"
   done
   log_msg "The following command will be invoked: "
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      log_msg "DRY-RUN: ${VTY_CALL} ${VTY_OPTS}"
   else
      CHANGES_MADE=true
      eval ${VTY_CALL} ${VTY_OPTS}
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
fi

if [ ${#REMOVE_CMDS[@]} -gt 0 ]; then
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      echo
      log_msg "DRY-RUN: The following commands have been added to remove-commands list:"
   fi
   VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
   VTY_OPTS=
   for REM_CMD in "${REMOVE_CMDS[@]}"; do
      if [ "x${DRY_RUN}" == "xtrue" ]; then
         log_msg "DRY-RUN: ${REM_CMD}"
      fi
      VTY_OPTS+=" -c '${REM_CMD}'"
   done
   log_msg "The following command will be invoked: "
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      log_msg "DRY-RUN: ${VTY_CALL} ${VTY_OPTS}"
   else
      CHANGES_MADE=true
      eval ${VTY_CALL} ${VTY_OPTS}
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
fi

#
# load the new running configuration
#
if [ ${#NEW_CMDS[@]} -gt 0 ]; then
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      echo
      log_msg "DRY-RUN: The following commands have been added to new-commands list:"
   fi
   VTY_CALL="${VTYSH} -E -d ${DAEMON} -c 'configure terminal'"
   VTY_OPTS=
   for NEW_CMD in "${NEW_CMDS[@]}"; do
      if [ "x${DRY_RUN}" == "xtrue" ]; then
         log_msg "DRY-RUN: ${NEW_CMD}"
      fi
      VTY_OPTS+=" -c '${NEW_CMD}'"
   done
   log_msg "The following command will be invoked: "
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      log_msg "DRY-RUN: ${VTY_CALL} ${VTY_OPTS}"
   else
      CHANGES_MADE=true
      eval ${VTY_CALL} ${VTY_OPTS}
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
fi

if [ "x${CHANGES_MADE}" != "xtrue" ]; then
   log_msg "No changes to be made."
   exit 0
fi

#
# BGP, clear session (soft)
#
if [ "x${DAEMON}" == "xbgpd" ]; then
   if [ "x${DRY_RUN}" == "xtrue" ]; then
      log_msg "DRY-RUN: clear ip bgp * soft"
   else
      ${VTYSH} -d ${DAEMON} -c 'clear ip bgp * soft' 2>&1 >/dev/null
      if [ "$?" != "0" ]; then
         log_failure_msg "vtysh returned non-zero for $DAEMON. please check manually."
         exit 1
      fi
   fi
fi
