:global updateEnvValue do={
    :local foundItem [/container/envs find list=$envArea  key=$envKey ]
    :if ([:len $foundItem] > 0) do={
:put "$envKey $envValue $envArea"

        /container/envs set $foundItem value=$envValue
    } else={
:put "$envKey $envValue $envArea"

        /container/envs add key=$envKey value=$envValue list=$envArea
    }
}

:global updateVlessSettings do={
    :global updateEnvValue

    $updateEnvValue envArea=$argArea envKey="ID"               envValue=$argID
    $updateEnvValue envArea=$argArea envKey="PUBLIC_KEY"       envValue=$argPbk
    $updateEnvValue envArea=$argArea envKey="REMOTE_ADDRESS"   envValue=$argRA
    $updateEnvValue envArea=$argArea envKey="REMOTE_PORT"      envValue=$argRP
    $updateEnvValue envArea=$argArea envKey="SERVER_NAME"      envValue=$argSN
    $updateEnvValue envArea=$argArea envKey="SHORT_ID"         envValue=$argSID
}

# $updateVlessSettings argID="ID" argArea="vless1" argPbk="PBK" argRA="RA" argRP="RP" argSN=SN argSID="argSID"

#$updateEnvValue envArea="vless2" envKey="K" envValue="V"
