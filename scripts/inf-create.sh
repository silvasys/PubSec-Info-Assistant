#!/bin/bash
set -e

printInfo() {
    printf "$YELLOW\n%s$RESET\n" "$1"
}

figlet Infrastructure

# Get the directory that this script is in
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
source "${DIR}/load-env.sh"
pushd "$DIR/../infra" > /dev/null

# reset the current directory on exit using a trap so that the directory is reset even on error
function finish {
  popd > /dev/null
}
trap finish EXIT

#set up variables for the bicep deployment
#get or create the random.txt from local file system
if [ -f ".state/${WORKSPACE}/random.txt" ]; then
  randomString=$(cat .state/${WORKSPACE}/random.txt)
else  
  randomString=$(mktemp --dry-run XXXXX)
  mkdir -p .state/${WORKSPACE}
  echo $randomString >> .state/${WORKSPACE}/random.txt
fi

if [ -n "${IN_AUTOMATION}" ]; then
  #if in automation, add the random.txt to the state container
  #echo "az storage blob exists --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --output tsv --query exists"
  exists=$(az storage blob exists --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --output tsv --query exists)
  #echo "exists: $exists"
  if [ $exists == "true" ]; then
    #echo "az storage blob download --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --query content --output tsv"
    randomString=$(az storage blob download --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --query content --output tsv)
    rm .state/${WORKSPACE}/random.txt
    echo $randomString >> .state/${WORKSPACE}/random.txt
  else
    #echo "az storage blob upload --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --file .state/${WORKSPACE}/random.txt"
    upload=$(az storage blob upload --account-name $AZURE_STORAGE_ACCOUNT --account-key $AZURE_STORAGE_ACCOUNT_KEY --container-name state --name ${WORKSPACE}.random.txt --file .state/${WORKSPACE}/random.txt)
  fi
fi
randomString="${randomString,,}"
export RANDOM_STRING=$randomString
signedInUserId=$(az ad signed-in-user show --query id --output tsv)
export SINGED_IN_USER_PRINCIPAL=$signedInUserId

#set up azure ad app registration since there is no bicep support for this yet
aadAppId=$(az ad app list --display-name infoasst_web_access_$RANDOM_STRING --output tsv --query [].appId)
if [ -z $aadAppId ]
  then
    aadAppId=$(az ad app create --display-name infoasst_web_access_$RANDOM_STRING --sign-in-audience AzureADMyOrg --identifier-uris "api://infoasst-$RANDOM_STRING" --web-redirect-uris "https://infoasst-web-$RANDOM_STRING.azurewebsites.net/.auth/login/aad/callback" --enable-access-token-issuance true --enable-id-token-issuance true --output tsv --query "[].appId")
    aadAppId=$(az ad app list --display-name infoasst_web_access_$RANDOM_STRING --output tsv --query [].appId)
  fi
export AZURE_AD_APP_CLIENT_ID=$aadAppId

aadSPId=$(az ad sp list --display-name infoasst_web_access_$RANDOM_STRING --output tsv --query "[].id")
if [ -z $aadSPId ]; then
    aadSPId=$(az ad sp create --id $aadAppId --output tsv --query "[].id")
    aadSPId=$(az ad sp list --display-name infoasst_web_access_$RANDOM_STRING --output tsv --query "[].id")
fi
if [ $REQUIRE_WEBSITE_SECURITY_MEMBERSHIP ]; then
  # if the REQUIRE_WEBSITE_SECURITY_MEMBERSHIP is set to true, then we need to update the app registration to require assignment
  az ad sp update --id $aadSPId --set "appRoleAssignmentRequired=true"
else
  # otherwise the default is to allow all users in the tenant to access the app
  az ad sp update --id $aadSPId --set "appRoleAssignmentRequired=false"
fi

#set up parameter file
declare -A REPLACE_TOKENS=(
    [\${WORKSPACE}]=${WORKSPACE}
    [\${LOCATION}]=${LOCATION}
    [\${SINGED_IN_USER_PRINCIPAL}]=${SINGED_IN_USER_PRINCIPAL}
    [\${RANDOM_STRING}]=${RANDOM_STRING}
    [\${AZURE_OPENAI_SERVICE_NAME}]=${AZURE_OPENAI_SERVICE_NAME}
    [\${GPT_MODEL_DEPLOYMENT_NAME}]=${AZURE_OPENAI_GPT_DEPLOYMENT}
    [\${CHATGPT_MODEL_DEPLOYMENT_NAME}]=${AZURE_OPENAI_CHATGPT_DEPLOYMENT}
    [\${USE_EXISTING_AOAI}]=${USE_EXISTING_AOAI}
    [\${AZURE_OPENAI_SERVICE_KEY}]=${AZURE_OPENAI_SERVICE_KEY}
    [\${BUILD_NUMBER}]=${BUILD_NUMBER}
    [\${AZURE_AD_APP_CLIENT_ID}]=${AZURE_AD_APP_CLIENT_ID}
)
parameter_json=$(cat "$DIR/../infra/main.parameters.json.template")
for token in "${!REPLACE_TOKENS[@]}"
do
  parameter_json="${parameter_json//"$token"/"${REPLACE_TOKENS[$token]}"}"
done
echo $parameter_json > $DIR/../infra/main.parameters.json

#make sure bicep is always the latest version
az bicep upgrade

#deploy bicep
az deployment sub what-if --location $LOCATION --template-file main.bicep --parameters main.parameters.json --name $RG_NAME
if [ -z $SKIP_PLAN_CHECK ]
    then
        printInfo "Are you happy with the plan, would you like to apply? (y/N)"
        read -r answer
        answer=${answer^^}
        
        if [[ "$answer" != "Y" ]];
        then
            printInfo "Exiting: User did not wish to apply infrastructure changes." 
            exit 1
        fi
    fi
results=$(az deployment sub create --location $LOCATION --template-file main.bicep --parameters main.parameters.json --name $RG_NAME)

#save deployment output
printInfo "Writing output to infra_output.json"
pushd "$DIR/.."
echo $results > infra_output.json