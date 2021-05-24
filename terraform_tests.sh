#!/usr/bin/env bash

set -e


declare -a paths

function infer_binary {
    local -r

    if ls $1/*.hcl &>/dev/null; then
        echo "terragrunt"
    elif ls $1/*.tf &>/dev/null; then
        echo "terraform"
    else
        extensions=()
        for file in $(ls $1); do
            filename=$(basename -- "$file")
            # extensions+=" ${filename##*.}"
            extensions+=$([[ "$filename" = *.* ]] && echo ".${filename##*.} ")
            echo $extensions
        done
        distinct_extensions=$(echo "${extensions[@]}" | tr " " "\n" | sort -u | tr "\n" " ")
        echo "Could not infer binary from $1" >&2
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
# gets directory names of filepath arguments
for filepath in "$@"; do
  filepath="${filepath// /__REPLACED__SPACE__}"
  #gets dir of filepath
  paths[index]=$(dirname "$filepath")
  let "index+=1"
done

# gets unique directory names
uniq_dirs=$(echo "${paths[*]}" | tr ' ' '\n' | sort -u)

for test_filepath in $(find tests/ -type d \( -name .terragrunt-cache -o -name .terraform \) -prune -false -o -name '*.hcl' -or -name '*.tf'); do
    logger "Checking test file: ${test_filepath}"  "DEBUG"
    test_dir=$(dirname $test_filepath)
    rel_paths=()
    for dir in ${uniq_dirs[@]}; do
        logger "test path: ${test_dir}" "DEBUG"
        logger "target directory: ${dir}" "DEBUG"
        # gets relative path of the test directory to the target paths
        rel_path=\"$(realpath --relative-to=${test_dir} ${dir})\"
        #for every relative path added after the first path, add `|` to represent OR for egrep
        if [ ${#rel_paths[@]} -eq 0 ]; then
            rel_paths+="${rel_path}"
        else
            rel_paths+="|${rel_path}"
        fi
        # get relative path with `//` instead of `/` for last directory within directory path
        # used to allow egrep to match tf module sources that use double slashes
        double_slash_path=$(echo "${rel_path}" | sed 's/\(.*\)\//\1\/\//')
        rel_paths+="|${double_slash_path}"
    done
    logger "Test relative path list: ${rel_paths[@]}" "DEBUG"

    if egrep -l "${rel_paths[@]}" $test_filepath; then
        echo "A dependency within test file: ${test_filepath} has changed"

        pushd "$test_dir" > /dev/null
        binary=$(infer_binary ".") || exit
        logger "Inferred binary: ${binary}" "INFO"

        cmd="${binary} test"
        echo "Running command: '${cmd}' within the directory: ${test_dir}"
        $cmd

        #rm path from dir stack
        popd > /dev/null
    else
        echo "Skipping test directory: $test_dir"
    fi
done
