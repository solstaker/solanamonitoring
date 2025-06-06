#!/bin/bash
# set -x # uncomment to enable debug

#####    Packages required: jq, bc, wget
#####    Solana Validator Monitoring Script v.0.14 to be used with Telegraf / Grafana / InfluxDB
#####    Fetching data from Solana validators, outputs metrics in Influx Line Protocol on stdout
#####    Created: 14 Jan 18:28 CET 2021 by Stakeconomy.com. Forked from original Zabbix nodemonitor.sh script created by Stakezone
#####    For support post your questions in the #monitoring channel in the Solana discord server

#####    CONFIG    ##################################################################################################
configDir="$HOME/.config/solana/" # the directory for the config files, eg.: /home/user/.config/solana
##### optional:        #
identityPubkey=""      # identity pubkey for the validator, insert if autodiscovery fails
voteAccount=""         # vote account address for the validator, specify if there are more than one or if autodiscovery fails
additionalInfo="on"    # set to 'on' for additional general metrics like balance on your vote and identity accounts, number of validator nodes, epoch number and percentage epoch elapsed
binDir=""              # auto detection of the solana binary directory can fail or an alternative custom installation is preferred, in case insert like $HOME/solana/target/release
rpcURL=""             # default is localhost with port number autodiscovered, alternatively it can be specified like http://custom.rpc.com:port
format="SOL"           # amounts shown in 'SOL' instead of lamports
now=$(date +%s%N)      # date in influx format
timezone=""            # time zone for epoch ends metric
#####  END CONFIG  ##################################################################################################

ip_address=$(ip route get 1 | awk '{print $7; exit}') 
cpu=$(lscpu | grep "Model name:" | head -n 1 | cut -c 12- |  sed 's/^ *//g')
solanaPrice=$(curl -s 'https://api.margus.one/solana/price/'| jq -r .price)
openfiles=$(cat /proc/sys/fs/file-nr | awk '{ print $1 }')


################# Added cluster network to grafana (1=testnet,2=mainnet,3=devnet)#########################
networkrpcURL=$(cat $configDir/cli/config.yml | grep json_rpc_url | grep -o '".*"' | tr -d '"')
if [ "$networkrpcURL" == "" ]; then networkrpcURL=$(cat /root/.config/solana/cli/config.yml | grep json_rpc_url | awk '{ print $2 }'); fi
if [ $networkrpcURL = https://api.testnet.solana.com ]; then network=1 networkname=testnet;
elif [ $networkrpcURL = https://api.mainnet-beta.solana.com ]; then network=2 networkname=mainnet;
elif [ $networkrpcURL = https://api.devnet.solana.com ]; then network=3 networkname=devnet;
else network=4 networkname=unknown; fi	
######################################################################################################

if [ -n  "$binDir" ]; then
   cli="${binDir}/solana"
else
   if [ -z $configDir ]; then echo "please configure the config directory"; exit 1; fi
   installDir="$(cat ${configDir}/install/config.yml | grep 'active_release_dir\:' | awk '{print $2}')/bin"
   if [ -n "$installDir" ]; then cli="${installDir}/solana"; else echo "please configure the cli manually or check the configDir setting"; exit 1; fi
fi

if [ -z $identityPubkey ]; then identityPubkey=$($cli address); fi

reserve_novoting() {
    #echo "please configure the vote account in the script or wait for availability upon starting the node"
    status=5 #status 0=validating 1=up 2=error 3=delinquent 4=stopped 5=no_voting
    logentry="nodemonitor status=$status,openFiles=$openfiles,network=$network,networkname=\"$networkname\",ip_address=\"$ip_address\",model_cpu=\"$cpu\" $now"
    echo $logentry
    exit 0
}

function durationToSeconds () {
  set -f
  normalize () { echo $1 | tr '[:upper:]' '[:lower:]' | tr -d "\"\\\'" | sed 's/years\{0,1\}/y/g; s/months\{0,1\}/m/g; s/days\{0,1\}/d/g; s/hours\{0,1\}/h/g; s/minutes\{0,1\}/m/g; s/min/m/g; s/seconds\{0,1\}/s/g; s/sec/s/g;  s/ //g;'; }
  local value=$(normalize "$1")
  local fallback=$(normalize "$2")

  echo $value | grep -v '^[-+*/0-9ydhms]\{0,30\}$' > /dev/null 2>&1
  if [ $? -eq 0 ]
  then
    >&2 echo Invalid duration pattern \"$value\"
  else
    if [ "$value" = "" ]; then
      [ "$fallback" != "" ] && durationToSeconds "$fallback"
    else
      sedtmpl () { echo "s/\([0-9]\+\)$1/(0\1 * $2)/g;"; }
      local template="$(sedtmpl '\( \|$\)' 1) $(sedtmpl y '365 * 86400') $(sedtmpl d 86400) $(sedtmpl h 3600) $(sedtmpl m 60) $(sedtmpl s 1) s/) *(/) + (/g;"
      echo $value | sed "$template" | bc
    fi
  fi
  set +f
}

if [ -z $rpcURL ]; then
   rpcPort=$(ps aux | grep agave-validator | grep -Po "\-\-rpc\-port\s+\K[0-9]+")
   if [ -z $rpcPort ]; then ### add firedancer
   config_path=$(ps aux | grep -v grep | grep 'fdctl run --config ' | sed -E 's/.*--config +([^[:space:]]+).*/\1/' | head -n 1)
   if [ -z $config_path ]; then
   rpcPort=""
   else
   rpcPort=$(awk '/^\[rpc\]/ {in_rpc=1; next} /^\[/ && !/^\[rpc\]/ {in_rpc=0} in_rpc && $1=="port" {gsub(/[^0-9]/, "", $3); print $3; exit}' "$config_path")
   fi
   fi
   if [ -z $rpcPort ]; then echo "nodemonitor status=4,openFiles=$openfiles,network=$network,networkname=\"$networkname\",ip_address=\"$ip_address\",model_cpu=\"$cpu\" $now"; exit 1; fi
   rpcURL="http://127.0.0.1:$rpcPort"
fi

noVoting=$(ps aux | grep agave-validator | grep -c "\-\-no\-voting")
if [ "$noVoting" -eq 0 ]; then
   if [ -z $identityPubkey ]; then identityPubkey=$($cli address --url $rpcURL); fi
   if [ -z $identityPubkey ]; then echo "auto-detection failed, please configure the identityPubkey in the script if not done"; exit 1; fi
   if [ -z $voteAccount ]; then voteAccount=$($cli validators --url $rpcURL --output json-compact | jq -r 'first (.validators[] | select(.identityPubkey == '\"$identityPubkey\"')) | .voteAccountPubkey'); fi
   if [ -z $voteAccount ]; then reserve_novoting; fi
fi

validatorCheck=$($cli validators --url $rpcURL --sort=credits -r -n)
validatorBalance=$($cli balance --url $rpcURL $identityPubkey | grep -o '[0-9.]*')
validatorVoteBalance=$($cli balance --url $rpcURL $voteAccount | grep -o '[0-9.]*')
jitoCommission=$(ps aux | grep agave-validator | grep -o -- '--commission-bps [0-9]*' | awk '{print $2/100}')
if [ -z $jitoCommission ]; then jitoCommission=100; fi


if [ $(grep -c $voteAccount <<< $validatorCheck) == 0  ]; then echo "validator not found in set"; exit 1; fi
    topCredits=$(echo "$validatorCheck" | awk -v pubkey="$identityPubkey" '$0 ~ pubkey { print $1 }')
    validatorSchedule=$($cli leader-schedule --url $rpcURL | grep $identityPubkey)
    totalSlots=$(echo "$validatorSchedule" | wc -l)
    if [ $totalSlots == "1" ];then totalSlots=0 ;fi
    blockProduction=$($cli block-production --url $rpcURL --output json-compact 2>&- | grep -v Note:)
    validatorBlockProduction=$(jq -r '.leaders[] | select(.identityPubkey == '\"$identityPubkey\"')' <<<$blockProduction)
    validators=$($cli validators --url $rpcURL --output json-compact 2>&-)
    currentValidatorInfo=$(jq -r '.validators[] | select(.voteAccountPubkey == '\"$voteAccount\"')' <<<$validators)
    delinquentValidatorInfo=$(jq -r '.validators[] | select(.voteAccountPubkey == '\"$voteAccount\"' and .delinquent == true)' <<<$validators)
    if [[ ((-n "$currentValidatorInfo" || "$delinquentValidatorInfo" ))  ]] || [[ ("$validatorBlockTimeTest" -eq "1" ) ]]; then
        status=1 #status 0=validating 1=up 2=error 3=delinquent 4=stopped
        blockHeight=$(jq -r '.slot' <<<$validatorBlockTime)
        blockHeightTime=$(jq -r '.timestamp' <<<$validatorBlockTime)
        if [ -n "$blockHeightTime" ]; then blockHeightFromNow=$(expr $(date +%s) - $blockHeightTime); fi
        if [ -n "$delinquentValidatorInfo" ]; then
              status=3
              activatedStake=$(jq -r '.activatedStake' <<<$delinquentValidatorInfo)
        if [ "$format" == "SOL" ]; then activatedStake=$(echo "scale=2 ; $activatedStake / 1000000000.0" | bc); fi
              credits=$(jq -r '.credits' <<<$delinquentValidatorInfo)
              version=$(jq -r '.version' <<<$delinquentValidatorInfo | sed 's/ /-/g')
              commission=$(jq -r '.commission' <<<$delinquentValidatorInfo)
              logentry="rootSlot=$(jq -r '.rootSlot' <<<$delinquentValidatorInfo),lastVote=$(jq -r '.lastVote' <<<$delinquentValidatorInfo),credits=$credits,activatedStake=$activatedStake,version=\"$version\",commission=$commission,jitoCommission=$jitoCommission"
        elif [ -n "$currentValidatorInfo" ]; then
              status=0
              activatedStake=$(jq -r '.activatedStake' <<<$currentValidatorInfo)
              credits=$(jq -r '.credits' <<<$currentValidatorInfo)
              version=$(jq -r '.version' <<<$currentValidatorInfo | sed 's/ /-/g')
              commission=$(jq -r '.commission' <<<$currentValidatorInfo)
              logentry="rootSlot=$(jq -r '.rootSlot' <<<$currentValidatorInfo),lastVote=$(jq -r '.lastVote' <<<$currentValidatorInfo)"
              leaderSlots=$(jq -r '.leaderSlots' <<<$validatorBlockProduction)
              skippedSlots=$(jq -r '.skippedSlots' <<<$validatorBlockProduction)
              totalBlocksProduced=$(jq -r '.total_slots' <<<$blockProduction)
              totalSlotsSkipped=$(jq -r '.total_slots_skipped' <<<$blockProduction)
              if [ "$format" == "SOL" ]; then activatedStake=$(echo "scale=2 ; $activatedStake / 1000000000.0" | bc); fi
              if [ -n "$leaderSlots" ]; then pctSkipped=$(echo "scale=2 ; 100 * $skippedSlots / $leaderSlots" | bc); fi
              if [ -z "$leaderSlots" ]; then leaderSlots=0 skippedSlots=0 pctSkipped=0; fi
              if [ -n "$totalBlocksProduced" ]; then
                 pctTotSkipped=$(echo "scale=2 ; 100 * $totalSlotsSkipped / $totalBlocksProduced" | bc)
                 pctSkippedDelta=$(echo "scale=2 ; 100 * ($pctSkipped - $pctTotSkipped) / $pctTotSkipped" | bc)
              fi
              if [ -z "$pctTotSkipped" ]; then pctTotSkipped=0 pctSkippedDelta=0; fi
              totalActiveStake=$(jq -r '.totalActiveStake' <<<$validators)
              totalDelinquentStake=$(jq -r '.totalDelinquentStake' <<<$validators)
              pctTotDelinquent=$(echo "scale=2 ; 100 * $totalDelinquentStake / $totalActiveStake" | bc)
              versionActiveStake=$(jq -r '.stakeByVersion.'\"$version\"'.currentActiveStake' <<<$validators)
              stakeByVersion=$(jq -r '.stakeByVersion' <<<$validators)
              stakeByVersion=$(jq -r 'to_entries | map_values(.value + { version: .key })' <<<$stakeByVersion)
              nextVersionIndex=$(expr $(jq -r 'map(.version == '\"$version\"') | index(true)' <<<$stakeByVersion) + 1)
              stakeByVersion=$(jq '.['$nextVersionIndex':]' <<<$stakeByVersion)
              stakeNewerVersions=$(jq -s 'map(.[].currentActiveStake) | add' <<<$stakeByVersion)
              totalCurrentStake=$(jq -r '.totalCurrentStake' <<<$validators)
              pctVersionActive=$(echo "scale=2 ; 100 * $versionActiveStake / $totalCurrentStake" | bc)
              pctNewerVersions=$(echo "scale=2 ; 100 * $stakeNewerVersions / $totalCurrentStake" | bc)
              logentry="$logentry,totalSlots=$totalSlots,leaderSlots=$leaderSlots,skippedSlots=$skippedSlots,pctSkipped=$pctSkipped,pctTotSkipped=$pctTotSkipped,pctSkippedDelta=$pctSkippedDelta,pctTotDelinquent=$pctTotDelinquent"
              logentry="$logentry,version=\"$version\",pctNewerVersions=$pctNewerVersions,commission=$commission,jitoCommission=$jitoCommission,activatedStake=$activatedStake,credits=$credits,solanaPrice=$solanaPrice"
           else status=2; fi
        if [ "$additionalInfo" == "on" ]; then
           nodes=$($cli gossip --url $rpcURL | grep -Po "Nodes:\s+\K[0-9]+")
           epochInfo=$($cli epoch-info --url $rpcURL --output json-compact)
           epoch=$(jq -r '.epoch' <<<$epochInfo)
           pctEpochElapsed=$(echo "scale=2 ; 100 * $(jq -r '.slotIndex' <<<$epochInfo) / $(jq -r '.slotsInEpoch' <<<$epochInfo)" | bc)
           validatorCreditsCurrent=$($cli vote-account --url $rpcURL $voteAccount | grep 'credits/max credits' | cut -d ":" -f 2 | cut -d "/" -f 1 | awk 'NR==1{print $1}')           
           EPOCH_INFO=$($cli epoch-info --url $rpcURL)
           FIRST_SLOT=`echo -e "$EPOCH_INFO" | grep "Epoch Slot Range: " | cut -d '[' -f 2 | cut -d '.' -f 1`
           LAST_SLOT=`echo -e "$EPOCH_INFO" | grep "Epoch Slot Range: " | cut -d '[' -f 2 | cut -d '.' -f 3 | cut -d ')' -f 1`
           CURRENT_SLOT=`echo -e "$EPOCH_INFO" | grep "Slot: " | cut -d ':' -f 2 | cut -d ' ' -f 2`
           EPOCH_LEN_TEXT=`echo -e "$EPOCH_INFO" | grep "Completed Time" | cut -d '/' -f 2 | cut -d '(' -f 1`
           EPOCH_LEN_SEC=$(durationToSeconds "${EPOCH_LEN_TEXT}")
           SLOT_LEN_SEC=`echo "scale=10; ${EPOCH_LEN_SEC}/(${LAST_SLOT}-${FIRST_SLOT})" | bc`
           SLOT_PER_SEC=`echo "scale=10; 1.0/${SLOT_LEN_SEC}" | bc`
           NEXT_SLOT=$(awk -v var=$CURRENT_SLOT '$1>=var' <(echo "$validatorSchedule") | head -n1 | cut -d ' ' -f3)
	   if [ -z "$NEXT_SLOT" ]; then NEXT_SLOT=$(awk -v var=$CURRENT_SLOT '$1<=var' <(echo "$validatorSchedule") | tail -n1 | cut -d ' ' -f3) ;fi
           LEFT_SLOTS=$((NEXT_SLOT-CURRENT_SLOT))
           leftToSlot=$(echo "scale=0; $LEFT_SLOTS * $SLOT_LEN_SEC" | bc | awk '{print int($1)}')           
           TIME=$(echo $EPOCH_INFO | grep "Epoch Completed Time" | cut -d "(" -f 2 | awk '{print $1,$2,$3,$4}')
           VAR1=$(echo $TIME | awk '{print $1}' | grep -o -E '[0-9]+')
           VAR2=$(echo $TIME | awk '{print $2}' | grep -o -E '[0-9]+')
           VAR3=$(echo $TIME | awk '{print $3}' | grep -o -E '[0-9]+')
           VAR4=$(echo $TIME | awk '{print $4}' | grep -o -E '[0-9]+')
           if [[ -z "$VAR4" && -z "$VAR3" && -z "$VAR2" ]];
           then
           epochEnds=$(TZ=$timezone date -d "$VAR1 seconds" +"%m/%d/%Y %H:%M")
           elif [[ -z "$VAR4" && -z "$VAR3" ]] ;
           then
           epochEnds=$(TZ=$timezone date -d "$VAR1 minutes $VAR2 seconds" +"%m/%d/%Y %H:%M")
           elif [ -z "$VAR4" ];
           then
           epochEnds=$(TZ=$timezone date -d "$VAR1 hours $VAR2 minutes $VAR3 seconds" +"%m/%d/%Y %H:%M")
           else
           epochEnds=$(TZ=$timezone date -d "$VAR1 days $VAR2 hours $VAR3 minutes $VAR4 seconds" +"%m/%d/%Y %H:%M")
           fi
           epochEnds=$(echo \"$epochEnds\")
           voteElapsed=$(echo "scale=4; $pctEpochElapsed / 100 * 6912000" | bc)
           pctVote=$(echo "scale=4; $validatorCreditsCurrent/$voteElapsed * 100" | bc)
           logentry="$logentry,openFiles=$openfiles,validatorBalance=$validatorBalance,validatorVoteBalance=$validatorVoteBalance,nodes=$nodes,epoch=$epoch,pctEpochElapsed=$pctEpochElapsed,validatorCreditsCurrent=$validatorCreditsCurrent,epochEnds=$epochEnds,slotSpeed=$SLOT_PER_SEC,slotTime=$SLOT_LEN_SEC,leftToSlot=$leftToSlot,pctVote=$pctVote,identityAccount=\"$identityPubkey\",voteAccount=\"$voteAccount\",topCredits=$topCredits,network=$network,networkname=\"$networkname\",ip_address=\"$ip_address\",model_cpu=\"$cpu\""
        fi
        logentry="nodemonitor,pubkey=$identityPubkey status=$status,$logentry $now"
    else
        status=2
        logentry="nodemonitor,pubkey=$identityPubkey status=$status,openFiles=$openfiles,network=$network,networkname=\"$networkname\",ip_address=\"$ip_address\",model_cpu=\"$cpu\" $now"
    fi
	

 echo $logentry
