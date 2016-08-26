#!/bin/bash

#set -e

usage()
{
    # TODO
    #if
    echo usage: keyvault.sh '<keyvaultname> <resource group name> <location> <secretname>'
}

creategroup()
{

    azure group show $rgname 2> /dev/null  
    if [ $? -eq 0 ]
    then    
        echo Resource Group $rgname already exists. Skipping creation.
    else
        # Create a resource group for the keyvault
        azure group create -n $rgname -l $location
    fi

}

createkeyvault()
{

    azure keyvault show $vaultname 2> /dev/null
    if [ $? -eq 0 ]
    then    
        echo Key Vault $vaultname already exists. Skipping creation.
    else   
        echo Creating Key Vault $vaultname.

        creategroup 
        # Create the key vault
        azure keyvault create --vault-name $vaultname --resource-group $rgname --location $location
    fi  

    azure keyvault set-policy -u $vaultname -g $rgname --enabled-for-template-deployment true --enabled-for-deployment true

}

convertcert()
{

cert=$1
key=$2
pfxfile=$3
pass=$4
    echo Creating PFX $pfxfile
    openssl pkcs12 -export -out $pfxfile -inkey $key -in $cert -password pass:$pass 2> /dev/null
    if [ $? -eq 1 ]
    then
        echo problem converting $key and $cert to pfx
        exit 1
    fi    

    fingerprint=$(openssl x509 -in $cert -noout -fingerprint | cut -d= -f2 | sed 's/://g' )

}

convertcacert()
{

    local cert=$1
    local pfxfile=$2
    local pass=$3

    echo Creating PFX $pfxfile
    openssl pkcs12 -export -out $pfxfile -nokeys -in $cert -password pass:$pass 2> /dev/null
    if [ $? -eq 1 ]
    then
        echo problem converting $cert to pfx
        exit 1
    fi    

    fingerprint=$(openssl x509 -in $cert -noout -fingerprint | cut -d= -f2 | sed 's/://g' )

}

storesecret()
{
    local secretfile=$1
    local name=$2
    filecontentencoded=$( cat $secretfile | base64 -w 0 )

json=$(cat << EOF
{
"data": "${filecontentencoded}",
"dataType" :"pfx",
"password": "${pwd}"
}
EOF
)

    jsonEncoded=$( echo $json | base64 -w 0 )

    r=$(azure keyvault secret set --vault-name $vaultname --secret-name $name --value $jsonEncoded)
    if [ $? -eq 1 ]
    then
        echo problem storing secret $name in $vaultname 
        exit 1
    fi    
    
    #echo $r 

    id=$(echo $r | grep -o 'https:\/\/[a-z0-9.]*/secrets\/[a-z0-9]*/[a-z0-9]*')
    echo Secret ID is $id

}

vaultname=$1
rgname=$2
location=$3
secretname=$4
certfile=$5
keyfile=$6
cacertfile=$7

pwd="blabla"

certpfxfile=${certfile%.*crt}.pfx
cacertpfxfile=${cacertfile%.*crt}.pfx
casecretname=ca$secretname

createkeyvault

# converting all certs to pfx
convertcert $certfile $keyfile $certpfxfile $pwd
certprint=$fingerprint
echo $certpfxfile fingerprint is $fingerprint
convertcacert $cacertfile $cacertpfxfile $pwd
echo $cacertpfxfile fingerprint is $fingerprint
cacertprint=$fingerprint

# storing pfx in keyvault
echo Storing $certpfxfile as $secretname
storesecret $certpfxfile $secretname
certid=$id   
echo Storing $cacertpfxfile as $casecretname
storesecret $cacertpfxfile $casecretname   
cacertid=$id

# make sure pattern substitution succeeds
cp ./azuredeploy.parameters.json.template ./azuredeploy.parameters.json

# update parameters file 
sed -i 's|REPLACE_CERTURL|'$certid'|g' ./azuredeploy.parameters.json
sed -i 's|REPLACE_CACERTURL|'$cacertid'|g' ./azuredeploy.parameters.json
sed -i 's/REPLACE_CERTPRINT/'$certprint'/g' ./azuredeploy.parameters.json
sed -i 's/REPLACE_CACERTPRINT/'$cacertprint'/g' ./azuredeploy.parameters.json
sed -i 's/REPLACE_VAULTNAME/'$vaultname'/g' ./azuredeploy.parameters.json
sed -i 's/REPLACE_VAULTRG/'$rgname'/g' ./azuredeploy.parameters.json

rm -f $certpfxfile
rm -f $cacertpfxfile

echo Done