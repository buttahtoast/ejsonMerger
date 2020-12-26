 #!/bin/bash

## -- Help Context
show_help() {
cat << EOF

Usage: ${0##*/} [-h] [-p] "ejson_key" [-s] "directory" [-m] "merge_directory" [-k] "secret_key" [-f] "dir/filename" [-r]
    -p ejson_key       Add EJSON private key to decrypt ejson files
    -s directory       Source directory for ejson files (will be searched recursive) [Default "."]
    -m merge_dir       Directory where your json/yml files are located to merge with secrets [Default "."]
    -k secret_key      Top level key for secrets to be mapped to - (( grab $.secret_key.* )) [Default "SECRETS"]
    -f dir/filename    Merge all files with Secrets in one json file. Given parameter is the name of the generated json
    -r                 Remove Secrets from merged files [Default: True]
    -y                 Output in YAML format [Default: JSON]
    -h                 Show this context

Script logs events/errors to [./${0##*/}.log]
EOF
}

## -- Default Variables
TIMESTAMP=$(date +%s)
SOURCE_DIRECTORY="."
MERGE_DIRECTORY="."
TMP_DIRECTORY="/tmp/ejson-merge"
TOPLEVEL_KEY="SECRETS"
JSON_FILE_NAME=""
REMOVE_SECRETS="true"
IS_EJSON="false"
IS_YAML=""
INPLACE="false"


## -- Opting arguments
OPTIND=1; # Reset OPTIND, to clear getopts when used in a prior script
while getopts ":hp:s:t:m:k:f:dy" opt; do
  case ${opt} in
    p)
       EJSON_PRIVATE_KEY="${OPTARG}";
       ;;
    s)
       SOURCE_DIRECTORY="${OPTARG}";
       ;;
    t)
       TMP_DIRECTORY="${OPTARG}";
       ;;
    m)
       MERGE_DIRECTORY="${OPTARG}"
       ;;
    k)
       TOPLEVEL_KEY="${OPTARG}"
       ;;
    f)
       JSON_FILE_NAME="${OPTARG}"
       ;;
    r)
       REMOVE_SECRETS="${OPTARG}"
       ;;
    y)
       IS_YAML="true"
       ;;

    h)
       show_help
       exit 0
       ;;
    ?)
       echo "Invalid Option: -$OPTARG" 1>&2
       exit 1
       ;;
  esac
done
shift $((OPTIND -1))

## -- Argument Checks

## -- Check if Ejson is installed/enabled
if [ -x "$(command -v ejson)" ]; then
  if [ -z "${EJSON_PRIVATE_KEY}" ]; then
    echo "No ejson private key given";
  else
    IS_EJSON="true"
  fi
else
   echo "Ejson is not installed";
fi

## -- Check if JQ is installed/enabled
if ! [ -x "$(command -v jq)" ]; then
   echo "Jq is not installed but required!" && exit 1;
fi

## -- Check if JQ is installed/enabled
if ! [ -x "$(command -v spruce)" ]; then
   echo "spruce is not installed but required!" && exit 1;
fi

## --- Source Directory
if ! [ -d "${SOURCE_DIRECTORY}" ]; then
   echo "Source directory '${SOURCE_DIRECTORY}' does not exist or is not accessible!";
   exit 1;
fi

## --- Merge Directory
if ! [ -d "${MERGE_DIRECTORY}" ]; then
   echo "Merge directory '${MERGE_DIRECTORY}' does not exist or is not accessible!";
   exit 1;
fi

## --- Mergeable Files
if [ $(find "${MERGE_DIRECTORY}" -type f \( -iname \*.yml -o -iname \*.json -o -iname \*.yaml \) | wc -l) -eq 0 ]; then
   echo "No files with extension (json/yml/yaml) found in '${MERGE_DIRECTORY}'!";
   exit 1;
fi

## --- Output file writeable
if ! [ -z "${JSON_FILE_NAME}" ]; then
   echo "T" > ${JSON_FILE_NAME};
   if [ $? -ne 0 ]; then
     echo "Could not write to destination '$JSON_FILE_NAME'";
     exit 1;
   fi
fi

# -- Syntax Check
find "${MERGE_DIRECTORY}" -iname '*.json' -type f -print0 -or -iname '*.ejson' -type f -print0 -or -iname '*.yml' -type f -print0 -or -iname '*.yaml' -type f -print0 | xargs -r -0 -n 1 sh -c 'spruce merge --skip-eval > /dev/null $0 || exit 1' || false
if [ $? -ne 0 ]; then
  echo "Syntax validation failed"
  cleanup;
  exit 1;
fi

## --- Temporary Directory
if ! [ -d "${TMP_DIRECTORY}" ]; then
   mkdir "${TMP_DIRECTORY}";
   if [ $? -ne 0 ]; then
      echo "Failed to create temp directory '${TMP_DIRECTORY}'";
      exit 1;
   fi
fi

## -- Cleanup
cleanup() {
  rm -rf "${TMP_DIRECTORY}" || true
}

## -- Debug Logging
debug() {
  echo "$(date) - $1" >> "./${0##*/}.log"
  return 0;
}

## -- Decrypt Secrets
if [ "${IS_EJSON,,}" == "true" ]; then
   SECRET_FILES=()
   SECRET_TMP="${TMP_DIRECTORY%/}/$TIMESTAMP.ejson"
   if [ $(find "${SOURCE_DIRECTORY}" -type f -iname "*.ejson" | wc -l) -ne 0 ]; then
      ## -- Get all Secret Files
      for file in $(find "${SOURCE_DIRECTORY}" -type f -name "*.ejson"); do
         JSON_RESULT=$(cat "${file}" | jq -r '.data' > /dev/null 2>> "./${0##*/}.log")
         if [[ $? -eq 0 ]] && [[ $JSON_RESULT != "null" ]]; then
            echo "${EJSON_PRIVATE_KEY}" | ejson decrypt -key-from-stdin "${file}" > /dev/null 2>> "./${0##*/}.log"
            if [ $? -ne 0 ]; then
               debug "Decryption failed for ${file}";
            else
               SECRET_FILES+=("$file")
            fi
            continue;
         else
            debug "Invalid JSON '${file}'. Does it have '.data'?";
            continue;
         fi
      done
   else
      debug "No files with ending 'ejson' found in directory '${SOURCE_DIRECTORY}'";
      IS_EJSON="false"
   fi

   ## -- Check if any Secrets matched
   if [ ${#SECRET_FILES[@]} -ne 0 ]; then
       ## -- Merge encrypted secrets and decrypt to memory variable
       spruce merge $(printf '%s ' "${SECRET_FILES[@]}") | spruce json | jq  > $SECRET_TMP 2>> "./${0##*/}.log"
       SECRETS=$(echo "${EJSON_PRIVATE_KEY}" | ejson decrypt -key-from-stdin $SECRET_TMP |  jq --arg KEY "$TOPLEVEL_KEY" '{($KEY): .data }' 2>> "./${0##*/}.log");
   else
       debug "No ejson file could be decrypted, does your private key match?";
       IS_EJSON="false"
   fi
fi



## -- Get all Mergeable Files
MERGE_ARRAY=()
readarray -d '' MERGE_ARRAY < <(find "${MERGE_DIRECTORY}" -iname '*.yml' -type f -or -iname '*.yaml' -type f -or -iname '*.json' -type f)
if [ ${#MERGE_ARRAY[@]} -eq 0 ]; then
   echo "No mergable files found under '${MERGE_DIRECTORY}'";
   exit 0;
fi

## -- Prepare render output
if [[ "${IS_EJSON,,}" == "true" ]]; then
  ## -- Syntax/Render
  echo "$SECRETS" | spruce merge $(printf '%s ' "${MERGE_ARRAY[@]}") - > /dev/null
  if [ $? -ne 0 ]; then
     debug "Invalid Syntax!" && exit 1;
  else
     ## -- Remove Secrets from Output
     if [[ "${REMOVE_SECRETS,,}" == "true" ]]; then
        ## -- Render without deticated secrets TOP Key
        OUTPUT_DATA=$(echo "$SECRETS" | spruce merge $(printf '%s ' "${MERGE_ARRAY[@]}") - | spruce json | jq --arg KEY "$TOPLEVEL_KEY" '. | del(.[$KEY])');
     else
        ## -- Render wit dedicated secrets TOP Key
        OUTPUT_DATA=$(echo "$SECRETS" | spruce merge $(printf '%s ' "${MERGE_ARRAY[@]}") - | spruce json);
     fi
   fi
else
 ## -- Syntax Check/Output Rendering Without Secrets
 spruce merge $(printf '%s ' "${MERGE_ARRAY[@]}") > /dev/null;
 if [ $? -ne 0 ]; then
   debug "Invalid Syntax!" && exit 1;
 else
   OUTPUT_DATA=$(spruce merge $(printf '%s ' "${MERGE_ARRAY[@]}") | spruce json)
 fi
fi


if ! [ -z "${OUTPUT_DATA}" ]; then
   ## -- Output Merged JSON to single file
   if ! [ -z "${JSON_FILE_NAME}" ]; then

     ## -- Output as YAML to file
     if ! [ -z "${IS_YAML}" ]; then
            echo $OUTPUT_DATA | jq -r '.' | ruby -ryaml -rjson -e 'puts YAML.dump(JSON.parse(STDIN.read))' > ${JSON_FILE_NAME} 2>> "./${0##*/}.log";
            if [ $? -ne 0 ]; then
              debug "YAML output failed!";
              FAILED_YAML="true"
            fi
     fi

     ## -- Output as JSON to file (Handle YAML err)
     if [[ "${FAILED_YAML,,}" == "true" ]] || [[ -z "${IS_YAML}" ]]; then
        echo $OUTPUT_DATA | jq -r '.' > ${JSON_FILE_NAME} 2>> "./${0##*/}.log";
        if [ $? -ne 0 ]; then
          debug "JSON Output failed!";
          exit 1;
        fi
     fi

   ## -- Output merged JSON to STDOUT
   else

     ## -- Output as YAML to file
     if ! [ -z "${IS_YAML}" ]; then
            echo $OUTPUT_DATA | jq -r '.' | ruby -ryaml -rjson -e 'puts YAML.dump(JSON.parse(STDIN.read))' 2>> "./${0##*/}.log";
            if [ $? -ne 0 ]; then
              debug "YAML output failed!";
              FAILED_YAML="true"
            fi
     fi

     ## -- Output as JSON to file (Handle YAML err)
     if [[ "${FAILED_YAML,,}" == "true" ]] || [[ -z "${IS_YAML}" ]]; then
        echo $OUTPUT_DATA | jq -r '.' 2>> "./${0##*/}.log";
        if [ $? -ne 0 ]; then
          debug "JSON Output failed!";
          exit 1;
        fi
     fi

   fi
else
   debug "Empty Data (Syntax Error)";
   exit 1;
fi


# -- End Execution
cleanup;
exit 1;
