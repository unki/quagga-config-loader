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

# Colors
readonly COLOR_RESTORE='\e[0m'
readonly COLOR_GREEN='\e[0;32m'
readonly COLOR_RED='\e[0;31m'

# found at https://raymii.org/s/snippets/Bash_Bits_Check_If_Item_Is_In_Array.html
in_array () {

    local -a 'haystack=("${'"$1"'[@]}")'
    for i in "${haystack[@]}"; do
        if [[ "${i}" =~ ${2} ]]; then
            return 0
        fi
    done
    return 1
}

log_begin_msg () {
   [ "x${DEBUG}" == "xtrue" ] || exit 0
   echo -n "$1"
}

log_end_msg () {

   [ "x${DEBUG}" == "xtrue" ] || exit 0

   if [ -z $! ]; then
      echo " done"
      return;
   fi

   if [[ $1 =~ ^[0-9]+$ ]]; then
      if [ $1 -eq 0 ]; then
         log_msg "done"
      elif [ $1 -eq 1 ]; then
         log_failure_msg "failed"
      else
         log_failure_msg " unknown (${1})"
      fi
      return
   fi

   echo " $1"
}

log_msg () {
   [ "x${DEBUG}" == "xtrue" ] || exit 0
   echo "$1"
}

log_success_msg () {
   echo -n ' '
   echo -en ${COLOR_GREEN}
   echo -n "${1}"
   echo -e ${COLOR_RESTORE}
}

log_failure_msg () {
   #[ "x${DEBUG}" == "xtrue" ] || exit 0
   echo -n ' '
   echo -en ${COLOR_RED}
   echo -n " ${1}"
   echo -e ${COLOR_RESTORE}
}

check_privileges () {
   if [ ! -z "${LOGNAME}" ] && [ "${LOGNAME}" == "root" ]; then
      return
   fi
   if [ ! -z "${USERNAME}" ] && [ "${USERNAME}" == "root" ]; then
      return
   fi
   if [ "$(id -un)" == "root" ]; then
      return
   fi

   log_failure_msg "`basename $0` must be invoked with root privileges!"
   exit 1
}

check_requirements () {
   if [ -z "${BASH_VERSION}" ]; then
      echo "\$BASH_VERSION variable is not set, is this really a Bash shell?"
      exit 1
   fi
   if [ -z "${BASH_VERSINFO[0]}" ]; then
      echo "\$BASH_VERSINFO variable is not set, is this really a Bash shell?"
      exit 1
   fi
   if [ ${BASH_VERSINFO[0]} -lt 4 ] || \
      ( [ ${BASH_VERSINFO[0]} == 4 ] && [ ${BASH_VERSINFO[1]} -lt 2 ] ); then
      echo "Bash >= v4.2 is required!"
      exit 1
   fi
}

check_configuration () {
   #
   # vtysh
   #
   if [ -z "${VTYSH}" ]; then
      log_failure_msg "\$VTYSH is not set!"
      exit 1
   fi
   if [ ! -e "${VTYSH}" ]; then
      log_failure_msg "vtysh not found at ${VTYSH}!"
      exit 1
   fi
   if [ ! -x "${VTYSH}" ]; then
      log_failure_msg "${VTYSH} is not executable!"
      exit 1
   fi

   #
   # quagga configuration directory.
   #
   if [ -z "${QUAGGA_CONF_DIR}" ]; then
      log_failure_msg "\$QUAGGA_CONF_DIR is not set!"
      exit 1
   fi
   if [ ! -d "${QUAGGA_CONF_DIR}" ]; then
      log_failure_msg "${QUAGGA_CONF_DIR} is not a directory!"
      exit 1
   fi
   if [ ! -x "${QUAGGA_CONF_DIR}" ]; then
      log_failure_msg "No permission to enter directory ${QUAGGA_CONF_DIR}!"
      exit 1
   fi

   #
   # prestaging directory.
   #
   if [ -z "${PRESTAGE_DIR}" ]; then
      log_failure_msg "\$PRESTAGE_DIR is not set!"
      exit 1
   fi
   if [ ! -d "${PRESTAGE_DIR}" ]; then
      log_failure_msg "${PRESTAGE_DIR} is not a directory!"
      exit 1
   fi
   if [ ! -x "${PRESTAGE_DIR}" ]; then
      log_failure_msg "No permission to enter directory ${PRESTAGE_DIR}!"
      exit 1
   fi

   #
   # BGP_IGNORE_NEIGHBOR_SHUTDOWN
   #
   if [ ! -z "${BGP_IGNORE_NEIGHBOR_SHUTDOWN}" ] && \
      [ "x${BGP_IGNORE_NEIGHBOR_SHUTDOWN}" != "x1" ]; then
      log_failure_msg "BGP_IGNORE_NEIGHBOR_SHUTDOWN needs to be either not set, 0 or 1!"
      exit 1
   fi

   #
   # failsafe settings
   #
   if [ ! -z "${FAILSAFE_MAX_NEIGHBORS_REMOVE}" ] && \
      ( ! [[ ${FAILSAFE_MAX_NEIGHBORS_REMOVE} =~ ^[[:digit:]]+$ ]] || \
      [ ${FAILSAFE_MAX_NEIGHBORS_REMOVE} -lt 0 ] ); then
      log_failure_msg "${FAILSAFE_MAX_NEIGHBORS_REMOVE} needs to be either not set, 0 or a positiv integer!"
      exit 1;
   fi
   if [ ! -z "${FAILSAFE_MAX_ROUTEMAPS_REMOVE}" ] && \
      ( ! [[ ${FAILSAFE_MAX_ROUTEMAPS_REMOVE} =~ ^[[:digit:]]+$ ]] || \
      [ ${FAILSAFE_MAX_ROUTEMAPS_REMOVE} -lt 0 ] ); then
      log_failure_msg "${FAILSAFE_MAX_ROUTEMAPS_REMOVE} needs to be either not set, 0 or a positiv integer!"
      exit 1;
   fi
   if [ ! -z "${FAILSAFE_NEVER_REMOVE_NEIGHBOR}" ]; then
      local NEIGHBOR
      IFS=' ' read -r -a FAILSAFE_NEVER_REMOVE_NEIGHBOR_ARRAY <<<"${FAILSAFE_NEVER_REMOVE_NEIGHBOR}"
      for NEIGHBOR in "${FAILSAFE_NEVER_REMOVE_NEIGHBOR_ARRAY[@]}"; do
         if ! [[ "${NEIGHBOR}" =~ ^[[:digit:]]{1,3}.[[:digit:]]{1,3}.[[:digit:]]{1,3}.[[:digit:]]{1,3}$ ]]; then
            log_failure_msg "${NEIGHBOR} does not seem to be a valid IPv4 address!"
            exit 1
         fi
      done
   fi
}

check_parameters () {
   if [ $# -lt 1 ] || [ -z $1 ]; then
      show_help;
      exit 0
   fi

   while getopts :hd:vtf OPTS; do
      ARGSPARSED=1
      case $OPTS in
         h)
            show_help
            exit 0
            ;;
         d)
            readonly DAEMON=${OPTARG,,}
            ;;
         v)
            readonly DEBUG=true
            ;;
         t)
            readonly DRY_RUN=true
            ;;
         f)
            readonly DO_WHAT_I_SAID=true
            ;;
         *)
            log_failure_msg "Invalid parameter(s)!"
            echo
            show_help
            exit 1
            ;;
      esac
   done

   if [ -z "${ARGSPARSED}" ] || [ -z "${DAEMON}" ]; then
      log_failure_msg "Invalid parameter(s)!"
      echo
      show_help
      exit 1
   fi

   if [ "x${DAEMON}" != "xospfd" ] && \
      [ "x${DAEMON}" != "xbgpd" ] && \
      [ "x${DAEMON}" != "xzebra" ]; then
      log_failure_msg "${1} is not supported!"
      exit 1
   fi
}

show_help ()
{
echo $0
echo
echo "  -d arg ... quagga daemon (ospfd, bgpd, zebra)"
echo "  -v     ... be verbose"
echo "  -t     ... dry-run (no changes are made)"
echo "  -f     ... force/do-what-I-said"
echo
}
