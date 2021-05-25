#!/usr/bin/env bash

set -e


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



modified_dir=()
for filepath in "$@"; do
  filepath="${filepath// /__REPLACED__SPACE__}"
  modified_dir+=$(dirname "$filepath")
done

# gets unique directory names
modified_dir=$(echo "${modified_dir[*]}" | tr ' ' '\n' | sort -u)

tf_dirs=()
for filepath in $(find ./ -type d \( -name .terragrunt-cache -o -name .terraform \) -prune -false -o -name '*.hcl' -or -name '*.tf'); do
    #trim extra slashes
    filepath=$(echo "${filepath// /__REPLACED__SPACE__}" | tr -s /)
    tf_dirs+="$(dirname $filepath) "
done

declare -a tf_dirs=$(echo $tf_dirs | tr ' ' '\n' | sort -u | tr '\n' ' ')

for tf_dir in $tf_dirs; do
    logger "terraform directory: ${tf_dir}" "DEBUG"
    cd $tf_dir
    # loads/updates terraform module sources to `.terraform/`
    terraform get -update
    # parse modules.json to get module source paths

    module_dep_paths=$(python -c "import json; print([module['Dir'] for module in [json.loads(line) for line in open('.terraform/modules/modules.json', 'r').read().split('\n')][0]['Modules']])")
    logger "Module dependency sources:" "DEBUG"
    logger "${module_dep_paths}" "DEBUG"

    rel_paths=()
    for dir in ${modified_dir[@]}; do
        logger "modified directory: ${modified_dir}" "DEBUG"
        # gets relative path of the terraform directory to the modified paths
        rel_paths+=$(realpath --relative-to=${tf_dir} ${modified_dir})
    done

    logger "relative path list: ${rel_paths[@]}" "DEBUG"

    for path in "${rel_paths[@]}"; do
        if [[ " ${module_dep_paths[@]} " =~ " ${path} " ]]; then
            echo "A module dependency within directory: ${tf_dir} has changed"

            binary=$(infer_binary ".") || exit
            logger "Inferred binary: ${binary}" "INFO"

            cmd="${binary} test"
            echo "Running command: '${cmd}' within the directory: ${tf_dir}"
            $cmd
            #rm path from dir stack
            cd - > /dev/null
            break
        fi
    done

    # if no modified files were passed as arguments or relative path is a module source path
    # if [ ! ${#rel_paths[@]} -ne 0 ] || [ ${modified_dep} = true ]; then

done
