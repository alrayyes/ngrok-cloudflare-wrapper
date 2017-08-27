#!/usr/bin/env bash

##
# @author Jay Taylor [@jtaylor]
# @date 2013-08-15
#
# @description CloudFlare management script.
#

# Path ENV VAR override.
if test -z "${CF_PATH:-}"; then
    CF_PATH="${HOME}/.cloudflare"
fi

# Ensure base path exists.
set -e
mkdir -p "${CF_PATH}" || ( echo "error: failed to create CF_PATH=${CF_PATH}" 1>&2 ; exit 1 )
set +e

##
# Begin Configuration
#

# NB: Hard-code these configuration values or place them in the corresponding file.
tkn=$(test -r "${CF_PATH}/token" && cat "${CF_PATH}/token" || echo '<YOUR_API_TOKEN_HERE>')
email=$(test -r "${CF_PATH}/email" && cat "${CF_PATH}/email" || echo '<YOUR_EMAIL_ADDRESS_HERE>')
zone=$(test -r "${CF_PATH}/zone" && cat "${CF_PATH}/zone" || echo '<YOUR_ZONE_HERE>')
ttl=$(test -r "${CF_PATH}/ttl" && cat "${CF_PATH}/ttl" || echo '<DEFAULT_TTL_SECONDS_HERE>')


# "service_mode" [applies to A/AAAA/CNAME]
# Status of CloudFlare Proxy, 1 = orange cloud, 0 = grey cloud.
cfProxy=0

#
# End Configuration
##

zid=$(test -r "${HOME}/.cloudflare/zid" && cat "${HOME}/.cloudflare/zid" || echo '')
# Attempt zone-id lookup if it is absent.
if test -z "${zid}"; then
    response=$(
        curl \
            --fail \
            --silent \
            --show-error \
            --compressed \
            -H "X-Auth-Email: ${email}" \
            -H "X-Auth-Key: ${tkn}" \
            "https://api.cloudflare.com/client/v4/zones?name=${zone}"
    )
    rc=$?
    if test $rc -ne 0; then
        echo "error: failed to lookup zone-id for domain name \"${zone}\", curl exit code=${rc}" 1>&2
        exit $rc
    else
        zid=$(
            echo "${response}" | python -c 'import json, sys
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
print(data.get("result", [{}])[0].get("id", "") if len(data.get("result", [])) > 0 else "")'
        )
        if test -z "${zid}"; then
            echo "error: no zone-id found matching domain name \"${zone}\"" 1>&2
            exit 1
        else
            echo "${zid}" > "${HOME}/.cloudflare/zid"
        fi
    fi
fi

if test -z "$1" || test "$1" = '-h' || test "$1" = '--help'; then
    echo "usage: $0 [ACTION] [additionalParameters?]..

ACTION - one of \"create\", \"read\", \"update\", \"delete\", or \"id\"" 1>&2
    exit 1
fi

action=$1


# Action aliases.
if test "${action}" = 'add' || test "${action}" = '+'; then action='create'; fi
if test "${action}" = 'edit' || test "${action}" = 'modify' || test "${action}" = '~'; then action='update'; fi
if test "${action}" = 'remove' || test "${action}" = 'rm' || test "${action}" = 'erase' || test "${action}" = '-'; then action='delete'; fi
if test "${action}" = 'list'; then action='read'; fi


# Validate action.
test "${action}" != 'create' && \
    test "${action}" != 'read' && \
    test "${action}" != 'update' && \
    test "${action}" != 'delete' && \
    test "${action}" != 'id' && \
    echo "error: unrecognized action \"${action}\" (see -h or --help), operation aborted" 1>&2 && exit 1 || true


# Translate requested action to CloudFlare's name for the action.
if test "${action}" = 'create'; then a='rec_new'; fi
if test "${action}" = 'read' || test "${action}" = 'id'; then a='rec_load_all'; fi
if test "${action}" = 'update'; then a='rec_edit'; fi
if test "${action}" = 'delete'; then a='rec_delete'; fi


if test "${action}" = 'id'; then
    test -z "$2" && echo 'error: missing required parameter: search query' 1>&2 && exit 1 || true
    results=''
    page=1
    while true; do
        searchQuery=$2
        response=$(
            curl \
                --fail \
                --silent \
                --show-error \
                --compressed \
                -H "X-Auth-Email: ${email}" \
                -H "X-Auth-Key: ${tkn}" \
                -H 'Content-Type: application/json' \
                "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records?page=${page}&per_page=100"
        )
        rc=$?
        if test $rc -ne 0; then
            echo "error: cloudflare dns record query failed on page=${page}, curl exit code=${rc}" 1>&2
            exit $rc
        fi
        result=$(
            echo "${response}" | python -c 'import json, sys
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
#sys.stderr.write("%s" % data)
for record in data.get("result", []):
    if record["type"].upper() in ("CNAME", "A", "TXT"):
        print("{0} {1} {2}".format(record["id"], record["name"], record["content"]))' \
            | grep "${searchQuery}"
        )
        results=$(echo -e -n "${results}\n${result}" | grep -v '^$')
        numRecords=$(
            echo "${response}" | python -c 'import json, sys
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
sys.stdout.write("%s" % (len(data.get("result", [])),))'
        )
        if test ${numRecords} -lt 100; then
            break
        fi
        page=$(($page + 1))
    done
    test -z "${results}" && echo "error: no results found for search query \"${searchQuery}\"" 1>&2 && exit 1 || true
    test $(echo "${results}" | wc -l) -gt 1 && echo -e "error: too many results found for search query \"${searchQuery}\":\n${results}" 1>&2 && exit 1 || true
    echo "${results}" | cut -d' ' -f1
    exit 0
fi


if test "${action}" = 'read'; then
    filter=$2
    page=1
    out='id\tname\tcontent
--\t----\t-------
'
    while true; do
        response=$(
            curl \
                --fail \
                --silent \
                --show-error \
                --compressed \
                -H "X-Auth-Email: ${email}" \
                -H "X-Auth-Key: ${tkn}" \
                -H 'Content-Type: application/json' \
                "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records?page=${page}&per_page=100"
        )
        rc=$?
        if test $rc -ne 0; then
            echo "error: cloudflare dns record query failed on page=${page}, curl exit code=${rc}" 1>&2
            exit $rc
        fi
        out="${out}
$(echo "${response}" | python -c 'import json, sys
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
for record in data.get("result", []):
    if record["type"].upper() in ("CNAME", "A", "TXT"):
        print("{0}\t{1}\t{2}".format(record["id"], record["name"], record["content"]))' \
        | grep "$(test -n "${filter}" && echo "${filter}" || echo '.*')")"
        numRecords=$(
            echo "${response}" | python -c 'import json, sys
data = json.loads(sys.argv[1] if len(sys.argv)>1 else sys.stdin.read())
sys.stdout.write("%s" % (len(data.get("result", [])),))'
        )
        if test ${numRecords} -lt 100; then
            break
        fi
        page=$(($page + 1))
    done
    column -t <<< "$(echo -e "${out}")"
fi


if test "${action}" = 'create'; then
    method='POST'
elif test "${action}" = 'update'; then
    method='PUT'
elif test "${action}" = 'delete'; then
    method='DELETE'
fi

apiUrl="https://api.cloudflare.com/client/v4/zones/${zid}/dns_records"
httpJsonData='{'

if test "${action}" = 'create' || test "${action}" = 'update'; then
    test -z "$2" && echo 'error: missing required parameter: subdomain name' 1>&2 && exit 1 || true
    httpJsonData="${httpJsonData}\"name\": \"$2\""
    test -z "$3" && echo 'error: missing required parameter: ip or cname hostname' 1>&2 && exit 1 || true

    if test -z "$4"; then
        if test -n "$(echo "$3" | grep '^[0-9\.]\+$')"; then
            httpJsonData="${httpJsonData}, \"type\": \"A\""
        else
            httpJsonData="${httpJsonData}, \"type\": \"CNAME\""
        fi
    else
        httpJsonData="${httpJsonData}, \"type\": \"$4\""
    fi
    httpJsonData="${httpJsonData}, \"content\": \"$3\", \"ttl\": ${ttl}"
fi


if test "${action}" = 'update'; then
    test -z "$2" && echo 'error: missing required parameter: subdomain name' && exit 1 || true
    test -z "$3" && echo 'error: missing required parameter: ip-address or target domain name' && exit 1 || true
    if test -n "$4"; then
        recordId="$4"
    else
        specifier=$2
        echo "info: attempting to resolve record id for \"${specifier}\"" 1>&2
        recordId=$("$0" id "${specifier}")
        rc=$?
        test $rc -ne 0 && echo "error: id resolution failed for specifier \"${specifier}\"" 1>&2 && exit 1 || true
    fi
    apiUrl="${apiUrl}/${recordId}"
    httpJsonData="${httpJsonData}, \"id\": \"${recordId}\""
fi

httpJsonData="${httpJsonData}}"

if test "${action}" = 'delete'; then
    test -z "$2" && echo 'error: missing required parameter: record specifier (id, or name to resolve to id)' 1>&2 && exit 1 || true
    # Test if specifier
    specifier=$2
    if test -z "$(echo "${specifier}" | grep '^[0-9a-f]\+')"; then
        echo "info: attempting to resolve record id for \"${specifier}\""
        recordId=$("$0" id "${specifier}")
        rc=$?
        test $rc -ne 0 && echo "error: id resolution failed for specifier \"${specifier}\"" 1>&2 && exit 1 || true
    fi
    apiUrl="${apiUrl}/${recordId}"
    httpJsonData=''
fi

if test "${action}" = 'create' || test "${action}" = 'update' || test "${action}" = 'delete'; then
    curl \
        --silent \
        --show-error \
        --fail \
        --compressed \
        -X "${method}" \
        -H 'Content-Type: application/json' \
        -H "X-Auth-Email: ${email}" \
        -H "X-Auth-Key: ${tkn}" \
        --data "${httpJsonData}" \
        "${apiUrl}"
    rc=$?
    echo ''
    if test $rc -ne 0; then
        echo "error: failed to ${action} record, curl return code=${rc}" 1>&2
        exit $rc
    fi
fi

exit 0
