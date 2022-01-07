#!/usr/bin/env bash

# ilya.vasilev@itglobal.com, 2021
# https://itgold.io
# https://github.com/itgoldio


### vars
# states for exit codes
STATE_OK=0              # define the exit code if status is OK
STATE_WARNING=1         # define the exit code if status is Warning
STATE_CRITICAL=2        # define the exit code if status is Critical
STATE_UNKNOWN=3         # define the exit code if status is Unknown

getScriptDir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd $getScriptDir

source ton-env.sh

# utils
bcBin=$( which bc )
bcArgs=" -ql "
bcLib="${getScriptDir}/bcLibForFloating"

grepBin=$( which grep )
cutBin=$( which cut )
trBin=$( which tr )
tailBin=$( which tail )
tailLines=100
headBin=$( which head )
divideValue=1000000000

version="0.6.0"

# show usage/help info and exit
usage() {
  echo "Usage: $0, ver. ${version}
-h   -- this help
-w   -- warning
-c   -- critical
-C   -- tonos-cli config file
-t   -- type
      
    These checks calls without -w and -c params:
          isValidatingNow
          isValidatingNext

    These checks requires warning and critical param:
          dePoolBalance
          timeDiff


  " 1>&2
  exit $STATE_UNKNOWN
}


getTonosCliVersion() {
  $TON_CLI --version | grep tonos_cli | awk '{print $2}'
}

getRNodeVersion() {
  $RNODE_BIN --version | grep version | awk '{print $4}'
}

getDePoolBalance() {

  versionAsNumber=$( echo "$( getTonosCliVersion)" | sed 's/\.//g' )
  if [[ $versionAsNumber -le 0246 ]]
  then
    myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG account $DEPOOL_ADDR | jq -r ".balance" )
  else
    myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG account $DEPOOL_ADDR | jq -r ".[].balance" )
  fi
  [[ -n $myRes ]] && echo $myRes || echo ""
}

checkStatus() {

  # *Balance - using script ./ton-*-balance.sh
  #   returning values from script: long
  #   returning code by check should be prepared:
  #     value / 1000000000 ? 30 >     -> 0 - ok
  #     value / 1000000000 ? 20..29   -> 1 - warn
  #     value / 1000000000 ? 19 <     -> 2 - crit
  #                                   -> 3 - unknown
  #    23.06.2021 - Dont using rounding now =)
  #     43772151034
  #    25.06.2021 - lets round!!!

  type=${1}
  warnValue=${2}
  critValue=${3}
  curValue=${4}
    
  case "$type" in
    walletBalance ) myMsg="Node wallet balance:" ;;
    dePoolBalance ) curValue=$( getDePoolBalance ) ; myMsg="DePool balance:" ;;
    proxy1balance ) myMsg="DePool proxy 1 balance:" ;;
    proxy2balance ) myMsg="DePool proxy 2 balance:" ;;
    tickTokBalance ) myMsg="TickTok balance:" ;;
  esac

  if [[ -z $curValue ]]
  then
    echo "UNKNOWN - $myMsg -1 | $type=-1;$warnValue;$critValue;;"
    exit $STATE_UNKNOWN
  fi

  evalRes=$( echo "$curValue/$divideValue" | ${bcBin} ${bcArgs} ${bcLib} )
  isWarn=$( echo "$evalRes<=$warnValue" | ${bcBin} ${bcArgs} ${bcLib} )
  isCrit=$( echo "$evalRes<=$critValue" | ${bcBin} ${bcArgs} ${bcLib} )

  if [[ $isWarn -ne 1 && $isCrit -ne 1 ]]
  then
    echo "OK - $myMsg $evalRes | $type=$evalRes;$warnValue;$critValue;;"
    exit $STATE_OK
  elif [[ $isWarn -eq 1 && $isCrit -ne 1 ]]
  then
    echo "WARNING - $myMsg $evalRes | $type=$evalRes;$warnValue;$critValue;;"
    exit $STATE_WARNING
  elif [[ $isCrit -eq 1 ]]
  then
    echo "CRITICAL - $myMsg $evalRes | $type=$evalRes;$warnValue;$critValue;;"
    exit $STATE_CRITICAL
  else
    echo "UNKNOWN - $myMsg $evalRes | $type=$evalRes;$warnValue;$critValue;;"
    exit $STATE_UNKNOWN
  fi
}

getElectorAddr(){
  $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c 'getconfig 1' | grep -iq error
  if [[ $? -ne 0 ]]
  then
    myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getconfig 1" | jq -r '.p1' )
    [[ -n $myRes ]] && echo "-1:${myRes}" || echo ""
  fi
}

getCurrentElectionsID() {
  # Ровно до тех пор пока мы едем в мейне на фифте
  # fift
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG runget $( getElectorAddr ) active_election_id | jq -r ".value0" )
  [[ -n $myRes ]] && echo "${myRes}" || echo ""
  # solidity
  # myRes=$( $TON_CLI -j run $( getElectorAddr ) active_election_id '{}' --abi ${Elector_ABI} | jq -r '.value0')
  # [[ -n $myRes ]] && echo "${myRes}" || echo ""
}

getAccountBalance() {
  myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getaccount $VALIDATOR_WALLET_ADDR" | jq -r ".balance" )
  [[ -n $myRes ]] && echo $myRes || echo ""
}

isValidatingNow() {
  myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getstats" | jq -r ".in_current_vset_p34" )
  if [[ -n $myRes ]]
  then
    echo "Current validator exist in P34 ( check via console: $myRes )"
    exit $STATE_OK
  else
    echo "Current validator not in P34 ( check via console: $myRes )"
    exit $STATE_CRITICAL
  fi
}

isValidatingNext() {
utime=$( date +%s )

# в этот период проверяем
TON_CURRENT_VALIDATION_END=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getconfig 34"  | jq -r ".p34.utime_until" )
TON_ELECTIONS_START_BEFORE=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getconfig 15"  | jq -r ".p15.elections_start_before" )

if [[ -z $TON_CURRENT_VALIDATION_END || -z $TON_ELECTIONS_START_BEFORE ]]
then
  echo -e "UNKNOWN - no data in .p34.utime_until or .p15.elections_start_before | validatingNext=-1;;;;"
  exit $STATE_UNKNOWN
fi

TON_ELECTIONS_START=$(($TON_CURRENT_VALIDATION_END - $TON_ELECTIONS_START_BEFORE))

if [[ $utime -ge $TON_ELECTIONS_START && $utime -le $TON_CURRENT_VALIDATION_END ]]
then
  myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getstats" | jq -r ".in_next_vset_p36" )
  if [[ "$myRes" == "true" ]]
  then
    echo "OK - Node will validate next round: 1 | validatingNext=1;;;;"
    exit $STATE_OK
  else
    echo "CRITICAL - Node will validate next round: 0 | validatingNext=0;;;;"
    exit $STATE_CRITICAL
  fi
else
  echo -e "UNKNOWN - Elections not defined yet | validatingNext=-1;;;;"
  exit $STATE_OK
fi
}

getTimeDiff() {
# timeDiff  - using script ./ton-node-diff.sh
#   returning values from script: integer
#   checking values and returning code by check
#     1 sec - 600 sec  - normal -> return 0
#     600 sec - 1199 sec - warning -> return 1
#     1200 sec > - critical -> return 2
#     0 < - unknown -> unknown 3
  warnValue=${1}
  critValue=${2}
  myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getstats" | jq -r ".timediff" )
  if [[ "$myRes" -lt "$warnValue" ]]
  then
    echo "OK - Node time diff: $myRes | timeDiff=$myRes;${warnValue};${critValue};;"
    exit $STATE_OK
  elif [[ "$myRes" -ge "$warnValue" && "$myRes" -lt "$critValue" ]]
  then
    echo "WARNING - Node time diff: $myRes | timeDiff=$myRes;${warnValue};${critValue};;"
    exit $STATE_WARNING
  elif [[ "$myRes" -ge "$critValue" ]]
  then
    echo "CRITICAL - Node time diff: $myRes | timeDiff=$myRes;${warnValue};${critValue};;"
    exit $STATE_CRITICAL
  else
    echo "UNKNOWN - Node time diff: $myRes | timeDiff=$myRes;${warnValue};${critValue};;"
    exit $STATE_UNKNOWN
  fi
}

### main script

if [ -z "${1}" ]
then
  usage
fi

while getopts ":w:c:t:hC:" myArgs
do
  case ${myArgs} in
    w) warnValue=${OPTARG} ;;
    c) critValue=${OPTARG} ;;
    t) typeCheck=${OPTARG} ;;
    C) configFile=${OPTARG} ;;
    h) usage ;;
    \?)  echo "Wrong option given. Check help ( $0 -h ) for usage."
        exit $STATE_UNKNOWN
        ;;
  esac
done

if [[ "${typeCheck}" == "isValidatingNow" ]]
then
  isValidatingNow
elif [[ "${typeCheck}" == "isValidatingNext" ]]
then
  isValidatingNext
elif [[ -n "${typeCheck}" && -n "${warnValue}" && -n "${critValue}" ]]
then
  while true
  do
    case "$typeCheck" in
      timeDiff ) getTimeDiff "${warnValue}" "${critValue}" ;;
      walletBalance )
        checkStatus walletBalance "${warnValue}" "${critValue}" $( "${tonScriptsDir}""${walletBalanceScript}" ) ;;
      dePoolBalance )
        checkStatus dePoolBalance "${warnValue}" "${critValue}" ;;
      proxy1balance )
        checkStatus proxy1balance "${warnValue}" "${critValue}" $( "${tonScriptsDir}""${depoolproxy1BalanceScript}" 2>/dev/null ) ;;
      proxy2balance )
        checkStatus proxy2balance "${warnValue}" "${critValue}" $( "${tonScriptsDir}""${depoolproxy2BalanceScript}" 2>/dev/null ) ;;
      tickTokBalance )
        checkStatus tickTokBalance "${warnValue}" "${critValue}" $( "${tonScriptsDir}""${tickTokBalanceScript}" ) ;;
      * )
        usage
        exit ${STATE_UNKNOWN}
        ;;
    esac
  done
else
  echo -e "Missing required parameter or parameters"
  usage
  exit ${STATE_UNKNOWN}
fi


exit 0

#!/usr/bin/env bash

source ton-env.sh

# =====================================================
Depool_addr=$DEPOOL_ADDR
Validator_addr=$VALIDATOR_WALLET_ADDR

# =====================================================
getElectorAddr(){
  $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c 'getconfig 1' | grep -iq error
  if [[ $? -ne 0 ]]
  then
    myRes=$( $TON_CONSOLE -j -C $TON_CONSOLE_CONFIG -c "getconfig 1" | jq -r '.p1' )
    [[ -n $myRes ]] && echo "-1:${myRes}" || echo ""
  fi
}

getCurrentElectionsID() {
  # Ровно до тех пор пока мы едем в мейне на фифте
  # fift
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG runget $( getElectorAddr ) active_election_id | jq -r ".value0" )
  [[ -n $myRes ]] && echo "${myRes}" || echo ""
  # solidity
  # myRes=$( $TON_CLI -j run $( getElectorAddr ) active_election_id '{}' --abi ${Elector_ABI} | jq -r '.value0')
  # [[ -n $myRes ]] && echo "${myRes}" || echo ""
}

getCurrentADNL() {
  allKeysFromConfig=$( cat $TON_NODE_CONFIG | jq .validator_keys )
  [[ "${allKeysFromConfig}" == "null" ]] && echo "null" && return
  elections0=$( echo $allKeysFromConfig | jq -r .[0].election_id )
  adnlKey0=$( echo $allKeysFromConfig | jq -r .[0].validator_adnl_key_id )
  [[ "${adnlKey0}" == "null" ]] && echo "null" && return
  elections1=$( echo $allKeysFromConfig | jq -r .[1].election_id )
  adnlKey1=$( echo $allKeysFromConfig | jq -r .[1].validator_adnl_key_id )
  if [[ "${adnlKey1}" == "null" ]]
  then
    myADNLKey=$( echo "${adnlKey0}" | base64 -d | od -t xC -An | tr -d '\n' | tr -d ' ' )
    myElectionsID=$elections0
  else
    currElectionsID=$(( elections0 < elections1 ? elections0 : elections1 ))
    nextElectionsID=$(( elections0 > elections1 ? elections0 : elections1 ))
    currADNLKey=$( echo $allKeysFromConfig | jq -r ".[]|select(.election_id == $currElectionsID)|.validator_adnl_key_id" | base64 -d | od -t xC -An | tr -d '\n' | tr -d ' ' )
    nextADNLKey=$( echo $allKeysFromConfig | jq -r ".[]|select(.election_id == $nextElectionsID)|.validator_adnl_key_id" | base64 -d | od -t xC -An | tr -d '\n' | tr -d ' ' )
  fi
  [[ -z "${adnlKey1}" || "${adnlKey1}" == "null" ]] && echo "${currADNLKey} ${currElectionsID}" || echo "${currADNLKey} ${currElectionsID} ${nextADNLKey} ${nextElectionsID}"
}

getP36Config() {
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG getconfig 36 | jq -r "." )
  echo "${myRes}"
}

getP34Config() {
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG getconfig 34 | jq -r "." )
  echo "${myRes}"
}

findInP34Config() {
  isInP34=$( echo "$( getP34Config )" | jq ".list[]|select(.adnl_addr == \"${1}\")" )
  if [[ -n $isInP34 ]]
  then
    adnl="$( echo ${isInP34} | jq -r .adnl_addr)"
    pkey="$( echo ${isInP34} | jq -r .public_key)"
    wght="$( echo ${isInP34} | jq -r .weight)"
    echo "${adnl} ${pkey} ${wght}"
  else
    echo "null"
  fi
} 

findInP36Config() {
  myRes=$( getP36Config )
  [[ $myRes == "null" ]] && echo "null" && return
  isInp36=$( echo "$( getP36Config )" | jq ".list[]|select(.adnl_addr == \"${1}\")" )
  if [[ -n $isInp36 ]]
  then
    adnl="$(echo ${isInp36} | jq -r .adnl_addr )"
    pkey="$(echo ${isInp36} | jq -r .public_key )"
    wght="$(echo ${isInp36} | jq -r .weight_dec )"
    echo "${adnl} ${pkey} ${wght}"
  else
    echo "null"
  fi
}

getParticipantListInElector() {
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG runget $( getElectorAddr ) participant_list_extended )  
  echo "${myRes}"
}

getElectionsFromElector() {
  myRes=$( $TON_CLI -j -c $TON_CLI_CONFIG runget $( getElectorAddr ) participant_list_extended | jq -r ".value0" )
  echo "${myRes}"
}

isValidatorInElector() {
  ADNL="${1}"
  allParticipantsFromElector=$( getParticipantListInElector )
  isElectionsOnGoing=$( getElectionsFromElector )
  [[ $isElectionsOnGoing -eq 0 ]] && echo "null" && return
  allParticipantsFromElector=$( echo "${allParticipantsFromElector}" | tr "]]" "\n" | tr '[' '\n' | awk 'NF > 0' | tr '","' ' ' )
  isMyADNLPresent=$( echo "${allParticipantsFromElector}" | grep -i "0x${ADNL}" )

  [[ -z $isMyADNLPresent ]] && echo "absent" && return

  stake=$( echo "${isMyADNLPresent}" | awk '{print $1}' )
  time=0
  max_factor=$( echo "${isMyADNLPresent}" | awk '{print $2}' )
  addr=$( echo "${allParticipantsFromElector}" | grep -B 1 "0x${ADNL}" | head -1 | cut -d 'x' -f 2 )
  echo "$stake $time $max_factor $addr"
}

# partCheck() {
# electionsID=$( getCurrentElectionsID )

# echo "Elections ID: $electionsID ( $( date -d@${electionsID} "+%F %T" ) ) DePool: $DEPOOL_ADDR Validator Wallet: $VALIDATOR_WALLET_ADDR"

# ADNLInfo=$( getCurrentADNL )

# [[ "${ADNLInfo}" == "null" ]] && echo "Validator never elected yet" && exit $STATE_UNKNOWN

# if [[ "${electionsID}" -eq 0 ]]
# then
#   currADNLKey=$( echo $ADNLInfo | awk '{print $3}' )
#   [[ -z $currADNLKey ]] && currADNLKey=$( echo $ADNLInfo | awk '{print $1}' )
#   ADNL_KEY=${ADNL_KEY:=$currADNLKey}
#   echo "Validator ADNL: $ADNL_KEY"

#   searchedADNL=$( findInP36Config $ADNL_KEY )
#   [[ "${searchedADNL}" == "null" ]] &&  searchedADNL=$( findInP34Config $ADNL_KEY ) &&  CurOrNextMSG="CURRENT" || CurOrNextMSG="NEXT"
  
#   validatorPubKey=$( echo "$searchedADNL" | awk '{print $1}' )
#   [[ "$validatorPubKey" == "absent" ]] && echo "###-ERROR: Your ADNL Key NOT FOUND in current or next validators list!!!" && exit 1

#   validatorWeight=$( echo "$searchedADNL" | awk '{print $2}' )
#   bcBin=$( which bc )
#   [[ ! -f $bcBin ]] && echo "WEIGHT BY BCFound you in $CurOrNextMSG validators with weight $(echo "scale=3; ${validatorWeight} / 10000000000000000" | $bcBin)%" || echo "WEIGHT WIYHOUT BC Found you in $CurOrNextMSG validators with weight ${validatorWeight}"
#   echo "Validator pub key: $validatorPubKey Your ADNL $(echo "$ADNL_KEY" | tr "[:upper:]" "[:lower:]") "
# fi

# Next_ADNL_Key=$( echo $ADNLInfo | awk '{print $3}' )
# [[ -z $Next_ADNL_Key ]] && Next_ADNL_Key=$( echo $ADNLInfo | awk '{print $1}' )
# ADNL_KEY=${ADNL_KEY:=$Next_ADNL_Key}

# ADNL_FOUND=$( isValidatorInElector $ADNL_KEY )
# [[ "$ADNL_FOUND" == "absent" ]] && echo "SEND TO TLG ###-ERROR: Can't find you in participant list in Elector. account: ${Depool_addr}" && exit 1 || echo "Found in Elector ADNL $ADNL_FOUND"

# Your_Stake=$( echo "${ADNL_FOUND}" | awk '{print $1 / 1000000000}' )
# You_PubKey=$( echo "${ADNL_FOUND}" | awk '{print $4}' )

# echo "stake= $( echo "${ADNL_FOUND}" | awk '{print $1 / 1000000000}' )  You_PubKey $( echo "${ADNL_FOUND}" | awk '{print $4}' )
# adnl_found is ${ADNL_FOUND}

# "


# echo "Stake: $Your_Stake ADNL: $( echo "$ADNL_KEY" | tr "[:upper:]" "[:lower:]" ) You public key in Elector: $You_PubKey You will start validate from $( date -d@${electionsID} "+%F %T" )"

# echo "
# ==
# getCurrentADNL is $( getCurrentADNL )
# ==
# "

# echo $electionsID > ${ELECTIONS_WORK_DIR}/curent_electionsID.txt
# for icinga
# echo "INFO
# ELECTION ID ${electionsID} ;
# DEPOOL ADDRESS $Depool_addr ;
# VALIDATOR ADDRESS $Validator_addr ;
# STAKE $Your_Stake ;
# ADNL ${ADNL_KEY} ;
# KEY IN ELECTOR $You_PubKey ;  
# "
# }

calcWeight() {
  bcBin=$( which bc )
  weight=${1}
  [[ "${weight}" == "null" || -z "${weight}" ]] && weight=0
  if [[ -e ${bcBin} ]]
  then
    echo "$( $bcBin -lq <<< "scale=3; ${weight} / 10000000000000000" )"
  else
    echo "${1}"
  fi
}

partCheck() {
  getADNLInfo=$( getCurrentADNL )
  [[ "${getADNLInfo}" == "null" ]] && echo "Validator never elected yet\n" && exit $STATE_UNKNOWN
  electionsID=$( getCurrentElectionsID )
  [[ "${electionsID}" -eq 0 ]] && myMSG="There is no election period\n" || myMSG="ElectionsID $electionsID, started at $( date -d@${electionsID} "+%F %T" )\n"

  currADNL=$( echo ${getADNLInfo} | awk '{print $1}' )
  isNextADNLReady=$( echo ${getADNLInfo} | awk '{print $3}' )
  if [[ -z $isNextADNLReady ]]
  then  
    myMSG="${myMSG}Current ADNL $currADNL \nNext ADNL EMPTY\n"
  else
    myMSG="${myMSG}Current ADNL $currADNL \nNext ADNL $( echo ${getADNLInfo} | awk '{print $3}' )\n"
  fi

  # search nextadnl
  searchedADNL=$( findInP36Config $isNextADNLReady )
  [[ "${searchedADNL}" != "null" ]] && myMSG="${myMSG}P36: ADNL: $( echo ${searchedADNL} | awk '{print $1}' ) PubKey: $( echo ${searchedADNL} | awk '{print $2}' ) Weight: $( echo ${searchedADNL} | awk '{print $3}' | calcWeight ) \n"
  searchedADNL=$( findInP34Config $isNextADNLReady )
  [[ "${searchedADNL}" != "null" ]] && myMSG="${myMSG}P34: ADNL: $( echo ${searchedADNL} | awk '{print $1}' ) PubKey: $( echo ${searchedADNL} | awk '{print $2}' ) Weight: $( echo ${searchedADNL} | awk '{print $3}' | calcWeight ) \n"

  # search curradnl
  searchedADNL=$( findInP36Config $currADNL )
  [[ "${searchedADNL}" != "null" ]] && myMSG="${myMSG}P36 ADNL: $( echo ${searchedADNL} | awk '{print $1}' ) PubKey: $( echo ${searchedADNL} | awk '{print $2}' ) Weight: $( echo ${searchedADNL} | awk '{print $3}' | calcWeight ) \n"
  searchedADNL=$( findInP34Config $currADNL )
  [[ "${searchedADNL}" != "null" ]] && myMSG="${myMSG}P34: ADNL: $( echo ${searchedADNL} | awk '{print $1}' ) PubKey: $( echo ${searchedADNL} | awk '{print $2}' ) Weight: $( echo ${searchedADNL} | awk '{print $3}' | calcWeight ) \n"

  if [[ "${electionsID}" -eq 0 ]]
  then
    findNextADNLInElector=$( isValidatorInElector $isNextADNLReady )
    [[ -n "${findNextADNLInElector}" && "${findNextADNLInElector}" != "null" ]] && myMSG="${myMSG}findNextADNLInElector is $findNextADNLInElector\n"

    findcurrADNLInElector=$( isValidatorInElector $currADNL )
    [[ -n "${findcurrADNLInElector}" && "${findNextADNLInElector}" != "null" ]] && myMSG="${myMSG}findCurrADNLInElector is $findcurrADNLInElector\n"
  fi

  echo -e "GRAND TOTAL:\n${myMSG}\n"
}
