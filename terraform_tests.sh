#!/usr/bin/env bash

set -e


declare -a paths

function infer_binary {
    local -r 

    if ls ${path}/*.hcl &>/dev/null; then
        echo "terragrunt"
    elif ls ${path}/*.tf &>/dev/null; then
        echo "terraform"
    else
        extensions=()
        for file in $(ls $path); do
            filename=$(basename -- "$file")
            extensions+=" ${filename##*.}"
        done

        distinct_extensions=$(echo "${extensions[@]}" | tr " " "\n" | sort -u | tr "\n" " ")
        echo "Could not infer binary from $path" >&2
        echo "Path only contains the following extensions:" >&2
        echo $distinct_extensions >&2
        exit 1
    fi
}

declare -a levels=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
script_logging_level="DEBUG"
logger() {
    local log_message=$1
    local log_priority=$2

    #check if level exists
    [[ ${levels[$log_priority]} ]] || return 1

    #check if level is enough
    (( ${levels[$log_priority]} < ${levels[$script_logging_level]} )) && return 2

    #log here
    echo "${log_priority} : ${log_message}"
}



index=0
# gets changed files
for filepath in "$@"; do
  filepath="${filepath// /__REPLACED__SPACE__}"
  #gets dir of filepath
  paths[index]=$(dirname "$filepath")
  let "index+=1"
done


# gets changed tf module dependencies
index=0
target_tests=()
for test_filepath in $(find tests/ -name '*.tf' -or -name '*.hcl'); do
    logger "Checking test file: ${test_filepath}"  "DEBUG"
    test_dir=$(dirname $test_filepath)
    for path_uniq in $(echo "${paths[*]}" | tr ' ' '\n' | sort -u); do
        # gets unique paths within `paths`
        path_uniq="${path_uniq//__REPLACED__SPACE__/ }"
        logger "test path: ${test_dir}" "DEBUG"
        logger "target path ${path_uniq}" "DEBUG"
        rel_paths[index]=$(realpath --relative-to=${test_dir} ${path_uniq})
        let "index+=1"
    done
    logger "Test relative path list: ${rel_paths[@]}" "DEBUG"
    
    if egrep -l "${rel_paths[@]}" $test_filepath; then
        pushd "$test_dir" > /dev/null
        binary=$(infer_binary $test_dir) || exit
        
        $binary test

        #rm path from dir stack
        popd > /dev/null
    else
        echo "Skipping test directory: $test_dir"
    fi
done