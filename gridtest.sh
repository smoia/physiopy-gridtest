#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# Usage helper
usage() {
    echo "Usage: $0 --start-ver <version> [--end-ver <version>] --package <pkg_path> --test <pytest-args>"
    echo "Example: $0 --start-ver 3.11.0 --end-ver 3.13.2 --package /path/to/phys2bids --test tests/test_core.py"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --start-ver) start_ver=$2; shift 2 ;;
        --end-ver)   end_ver=$2;   shift 2 ;;
        --package)   pkg_path=$2;  shift 2 ;;
        --test)      test_args=$2; shift 2 ;;
        *) usage ;;
    esac
done

if [[ -z ${start_ver} || -z ${pkg_path} || -z ${test_args} ]]; then
    usage
fi

# Ensure pyenv is available
if ! command -v pyenv &> /dev/null; then
    echo "Error: pyenv is not installed or not in your PATH."
    exit 1
fi

echo "Updating pyenv index..."
pyenv update &> /dev/null || true

echo "Fetching available Python versions..."
# Get all available definitions matching standard CPython versions (e.g., 3.x.x)
available_versions=$(pyenv install --list | grep -E '^  [0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^[[:space:]]*//')

# Function to convert version string to a comparable integer (padded to 3 digits per block)
version_pad() {
    echo "$1" | awk -F. '{ printf("%03d%03d%03d\n", $1,$2,$3); }'
}

start_pad=$(version_pad ${start_ver})
end_pad=""
if [[ -n ${end_ver} ]]; then
    end_pad=$(version_pad ${end_ver})
fi

# Filter versions based on criteria
target_versions=()
for ver in ${available_versions}; do
    ver_pad=$(version_pad "${ver}")
    
    if [[ -n ${end_pad} ]]; then
        # Range mode: Start <= Current <= End
        if [[ ${ver_pad} -ge ${start_pad} && ${ver_pad} -le ${end_pad} ]]; then
            target_versions+=("${ver}")
        fi
    else
        # Open-ended mode: Current >= Start
        if [[ ${ver_pad} -ge ${start_pad} ]]; then
            target_versions+=("${ver}")
        fi
    fi
done

if [[ ${#target_versions[@]} -eq 0 ]]; then
    echo "No matching Python versions found for the criteria."
    exit 0
fi

echo "Found ${#target_versions[@]} versions to process."
echo "-----------------------------------------------"

# Track test results
declare -A results

for ver in "${target_versions[@]}"; do
    echo -e "\n=== Processing Python ${ver} ==="
    
    # 1. Check if installed, if not, install it
    if ! pyenv versions --bare | grep -q "^${ver}$"; then
        echo "--> Installing Python ${ver} via pyenv (this may take a while)..."
        pyenv install ${ver}
    else
        echo "--> Python ${ver} is already installed."
    fi

    # Set local path context to use this specific python version
    pyenv_version_bin="$(pyenv root)/versions/${ver}/bin/python"
    
    # 2. Setup isolated virtualenv using the specific pyenv python executable
    env_dir="./env_${ver}"
    echo "--> Creating virtualenv in ${env_dir}..."
    ${pyenv_version_bin} -m venv ${env_dir}
    
    # 3. Activate environment
    echo "--> Activating environment..."
    # Disable exit-on-error temporarily because some activation scripts throw non-critical unbound variable notices
    set +e
    source ${env_dir}/bin/activate
    set -e
    
    # Ensure pip, pytest, and the target package are installed inside the venv
    echo "--> Installing ${pkg_path}..."
    pip install --upgrade pip &> /dev/null
    cd ${pkg_path}
    pip install -e .[all] &> /dev/null
    pip install -e .[dev] &> /dev/null
    
    # 4. Run the provided test suite
    echo "--> Running pytest ${test_args}..."
    set +e
    pytest ${test_args}
    test_exit_code=$?
    set -e
    
    if [ $test_exit_code -eq 0 ]; then
        results["${ver}"]="PASSED"
    else
        results["${ver}"]="FAILED"
    fi
    
    # 5. Deactivate environment & cleanup directory
    echo "--> Deactivating and cleaning up..."
    deactivate
    rm -rf "${env_dir}"
done

# Print final report summary
echo -e "\n=============================="
echo "        TEST SUMMARY"
echo "=============================="
for ver in ${target_versions[@]}; do
    echo "Python ${ver}: ${results[${ver}]}"
done
echo "=============================="