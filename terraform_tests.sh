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


modified_dirs=()
if [ ${#@} -ne 0 ]; then
    for filepath in "$@"; do
        filepath="${filepath// /__REPLACED__SPACE__}"
        # gets abs path of modified directory
        modified_dirs+=$(cd $(dirname "$filepath") && pwd && cd - > /dev/null)
    done
else
    echo "No filepath arguments were passed"
    exit 1
fi

# gets unique directory names
modified_dirs=$(echo "${modified_dirs[*]}" | tr ' ' '\n' | sort -u)

test_dirs=()
# gets directory paths within `tests/` that contain .tf or .hcl files but ignore .terra*/
for filepath in $(find tests/ -type d \( -name .terragrunt-cache -o -name .terraform \) -prune -false -o -name '*.hcl' -or -name '*.tf'); do
    #trim extra slashes
    filepath=$(echo "${filepath// /__REPLACED__SPACE__}" | tr -s /)
    test_dirs+="$(dirname $filepath) "
done

# get unique test sub directories
declare -a test_dirs=$(echo $test_dirs | tr ' ' '\n' | sort -u | tr '\n' ' ')

for tf_dir in $test_dirs; do
    cd "$tf_dir" > /dev/null
    echo ""
    binary=$(infer_binary ".") || exit
    logger "Inferred binary: ${binary}" "INFO"
    logger "${binary} directory: ${tf_dir}" "DEBUG"

# use terragrunt source path as module_dep_paths
    if [ "${binary}" == "terragrunt" ]; then
        # get local terraform module source path from terragrunt file to list
        tg_dep_path=$(grep -Pzo 'terraform\s+\{(\s+.+)+source\s+=\s+\"\K(\.\.\/+)+.+(?=\"\s+\})' terragrunt.hcl |  sed 's/\/\//\//g')
        if [[ -n ${tg_dep_path} ]]; then
            # create tmp tf module file that uses the tg source path
            cat <<EOF > tmp.tf
module "test" {
    source = "${tg_dep_path}"
}
EOF
        fi
    fi

    # loads/updates terraform module sources to `.terraform/`
    terraform get -update
    # parse modules.json to get module source paths
    module_dep_paths=$(python -c "import json; print(str({module['Dir'] for module in [json.loads(line) for line in open('.terraform/modules/modules.json', 'r').read().split('\n')][0]['Modules']}).replace('{', '').replace('}', '').replace(\"'\", '').replace(',', ''))")
    logger "Module dependency sources:" "DEBUG"
    logger "${module_dep_paths}" "DEBUG"

    if [ "${binary}" == "terragrunt" ] && [ -f "tmp.tf" ] ; then
        #clean up .tf files before running terragrunt cmd
        rm tmp.tf
    fi

    rel_paths=()
    for dir in ${modified_dirs[@]}; do
        logger "modified directory path: ${dir}" "DEBUG"
        # gets relative path of the test directory to the modified paths
        rel_paths+=$(realpath --relative-to=${PWD} ${dir})
    done

    logger "relative path list: ${rel_paths[@]}" "DEBUG"

    for i in "${!rel_paths[@]}"; do
        logger "Searching for: ${rel_paths[$i]} within Terraform module dependency paths: ${module_dep_paths[@]}"
        if [[ " ${module_dep_paths[@]} " =~ " ${rel_paths[$i]} " ]]; then
            echo "A module dependency within directory: '${tf_dir}' has changed"

            cmd="${binary} test"
            echo "Running command: '${cmd}' within the directory: '${tf_dir}'"
            $cmd
            break
        fi

        if [[ "${i+1}" ==  ${#rel_paths[@]} ]]; then
            echo "No module dependencies were changed within directory '${tf_dir}'"
            echo "Skipping command: '${cmd}' within the directory: ${tf_dir}"
        fi
    done

    cd - > /dev/null

done
