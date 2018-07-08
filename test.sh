#!/usr/bin/env bash

### PROJECT DEFAULTS ###
# To override these values, use the --generate-rc-file switch and modify the generated file

ENABLE_DOCTESTS=true
ENABLE_UNITTESTS=true
ENABLE_COVERAGE=true
ENABLE_BDD=false
ENABLE_TYPES=true
ENABLE_TODOS=true
ENABLE_SONAR=false

MIN_PYTHON_VERSION="3.3.0"
MAX_PYTHON_VERSION="3.7.0"

SOURCES_FOLDER='src'
TESTS_FOLDER='tests'
UNIT_TESTS_FOLDER="${TESTS_FOLDER}/unit"
BDD_TESTS_FOLDER="${TESTS_FOLDER}/features"

SONAR_SERVER='http://localhost:9000'
SONAR_TEAM=''
SONAR_PROJECT=''
SONAR_PROJECT_VERSION='1.0'

GITHUB_UPDATE_PERSONAL_ACCESS_TOKEN=''
GITHUB_UPDATE_REPOSITORY='<owner>/<repository>/<branch>'
GITHUB_UPDATE_TEST_SCRIPT='test.sh'
declare -A GITHUB_UPDATE_SOURCES_TARGETS=(
    ["${GITHUB_UPDATE_TEST_SCRIPT}"]="$(basename "$0")"
    ["tests/.pylintrc"]="${TESTS_FOLDER}/.pylintrc"
    ["api/.pylintrc"]="${SOURCES_FOLDER}/.pylintrc"
)

COVERAGE_MIN_PERCENTAGE=69
TODOS_LIMIT_PER_PERSON=10

### DON'T CHANGE ANYTHING AFTER THIS POINT ###

ROOT_FOLDER="$( cd "$( dirname "$0" )" && pwd )"
cd "${ROOT_FOLDER}"

BRED='\033[1;31m'
BGREEN='\033[1;32m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color
SONAR_FILE='sonar-project.properties'
SONAR_REPORT='sonar_report.json'
SONAR_SCANNER_VERSION="3.1.0.1141"
SONAR_SCANNER_ZIP_FILE="sonar-scanner-cli-${SONAR_SCANNER_VERSION}.zip"
SONAR_SCANNER_ZIP_FOLDER="sonar-scanner-${SONAR_SCANNER_VERSION}"
SONAR_SCANNER_URL="https://sonarsource.bintray.com/Distribution/sonar-scanner-cli/${SONAR_SCANNER_ZIP_FILE}"
PYLINT_REPORT="pylint_report.sonar"
TEST_RC_FILE=".testrc"
declare -A TEST_RC_FILE_HEAD_OFFSET=( ["start"]=6 ["end"]=35 )
XUNIT_FILE="nosetests.xml"
COVERAGE_FILE="coverage.xml"

if [[ -f ${TEST_RC_FILE} ]]; then
    echo "Using '${TEST_RC_FILE}'."
    source ${TEST_RC_FILE}
else
    echo "No '${TEST_RC_FILE}' found. Using global values. You can generate one with --generate-rc-file."
fi

[[ -n ${GITHUB_UPDATE_PERSONAL_ACCESS_TOKEN} ]] && TOKEN="${GITHUB_UPDATE_PERSONAL_ACCESS_TOKEN}@" || TOKEN=""
GITHUB_UPDATE_BASE_URL="https://${TOKEN}raw.githubusercontent.com/${GITHUB_UPDATE_REPOSITORY}"
ENABLE_NOSE=false; ${ENABLE_DOCTESTS} || ${ENABLE_UNITTESTS} || ${ENABLE_COVERAGE} && ENABLE_NOSE=true

export PYTHONPATH="$(pwd)/${SOURCES_FOLDER}:$(pwd):${PYTHONPATH}"  # PYTHONPATH for imports

CURRENT_OS="$(uname -s)"
PIPS=("pip3" "pip")
VENV=".venv_${CURRENT_OS}"
PYTHON_EXE=""

if [[ "${CURRENT_OS}" =~ (CYGWIN|MINGW).* ]]; then
    PYTHONS=("python3.exe" "python.exe")
    VENV_ACTIVATE="${VENV}/Scripts/activate"
    COVER_PATH="$(cygpath.exe -w "$(pwd)")"
    VENV_SUDO=""
    export PATH="/usr/local/bin:/usr/bin:$PATH"
    SONAR_SCANNER="${VENV}/bin/sonar-scanner.bat"
else
    VENV_SUDO="echo 'Needs sudo to install virtualenv via pip.'; sudo -H "
    PYTHONS=("python3" "python")
    VENV_ACTIVATE="${VENV}/bin/activate"
    COVER_PATH="$(pwd)"
    SONAR_SCANNER="${VENV}/bin/sonar-scanner"
fi

# Discover python executable on current OS
for py in ${PYTHONS[*]}; do
    ${py} --version >/dev/null 2>&1
    if [[ $? -eq 0 ]]; then
        PYTHON_EXE="${py}"
        break
    fi
done

if [[ -z "${PYTHON_EXE}" ]]; then
    test_exit 253 "No python executable found."
fi

# platform-specific command to open an HTML file in a default browser
[[ "${CURRENT_OS}" == "Darwin" ]] && WEBSITE_OPENER="open" || WEBSITE_OPENER="${PYTHON_EXE} -m webbrowser -t"

# RUNTIME GLOBALS
failed=0
result_code=0
fail_strict=false

sigint_handler() {
    echo "Terminating ..."
    exit 1
}

trap sigint_handler INT

cleanup() {
    rm -rf "${PYLINT_REPORT}" "${COVERAGE_FILE}" "${XUNIT_FILE}" .scannerwork \
    "${SONAR_SCANNER_ZIP_FILE}" "${SONAR_SCANNER_ZIP_FOLDER}" "${SONAR_REPORT}"
}

cleanup

# Tests exit code. Exits on failure and prints message.
# On success, prints optional message.
# $1 = return code to check. 0 is success, anything else failure
# $2 = error message
# $3 = optional success message
test_exit() {
    if [[ $1 -ne 0 ]]; then
        echo -e "$2"
        cleanup
        exit $1
    elif [[ -n ${3+x} ]]; then
        echo -e "$3"
    fi
}

# Marks a test as failed/passed with a message base on return code.
# $1 = exit code to test
# $2 = test type (string)
# $3 = trailing string (optional)
test_failed() {
    if [[ $1 -ne 0 ]]; then
        failed=$(expr ${failed} + 1);
        [[ ${fail_strict} == true ]] && result_code=1
        echo -e "${BRED}$2 failed.${3:-}${NC}"
        return 1
    fi

    echo -e "${GREEN}$2 passed.${3:-}${NC}"
}

# The same as test failed, but also sets the return code.
test_failed_strict() {
    test_failed "$@"
    if [[ $1 -ne 0 ]]; then
        result_code=1
    fi
}

# $1 - utility name
# $2 - command to run to check if it is installed
terminate_if_not_installed() {
    $2 >/dev/null 2>&1
    test_exit $? "Please install '$1' utility."
}

[[ ${ENABLE_SONAR} == true && ! -f "${SONAR_SCANNER}" ]] && terminate_if_not_installed 'unzip' 'unzip -v'
[[ ${ENABLE_SONAR} == true ]] && terminate_if_not_installed 'curl' 'curl --help'

# Check if discovered python version is within allowed range.
check_supported_python_version() {
    ver() {
        printf "%03d%03d%03d%03d" $(echo "$1" | tr '.' ' ')
    }
    local py_version="$(${PYTHON_EXE} --version 2>&1 | cut -d ' ' -f 2)"
    [[ "${CURRENT_OS}" =~ (CYGWIN|MINGW).* ]] && py_version="$(echo ${py_version} | tr --delete '\r')"
    [[ $(ver "${py_version}") -ge $(ver "${MIN_PYTHON_VERSION}") && $(ver "${py_version}") -le $(ver "${MAX_PYTHON_VERSION}") ]]
    test_exit $? "Python version ${py_version} is not supported. Supported versions range is <${MIN_PYTHON_VERSION}, ${MAX_PYTHON_VERSION}>.\nUse '-pe' option to specify different python executable."
}

# Discovers pip executable on current OS
discover_pip() {
    for pie in ${PIPS[*]}; do
        ${pie} --version >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            echo "${pie}"
            return 0
        fi
    done

    return 1
}

PIP_EXE="$(discover_pip)"
test_exit $? "No pip executable found. Please install pip."

while [[ "$#" > 0 ]]; do
    case $1 in
        -o|--browser) open_in_browser=true;;
        -p|--pylint) use_pylint=true;;
        -t|--types) use_typecheck=true;;
        -d|--doctests) use_doctests=true;;
        -u|--unittests) use_unittests=true;;
        -c|--coverage) use_coverage=true;;
        -b|--bdd) use_bdd=true;;
        --todo) use_todos=true;;
        -s|--sonar) use_sonar=true;;
        -np|--no-pylint) use_pylint=false;;
        -nt|--no-types) use_typecheck=false;;
        -nd|--no-doctests) use_doctests=false;;
        -nu|--no-unittests) use_unittests=false;;
        -nc|--no-coverage) use_coverage=false;;
        -nb|--no-bdd) use_bdd=false;;
        --no-todo) use_todos=false;;
        -ns|--sonar) use_sonar=false;;
        -f) use_file="$2"; shift;;
        -tf) use_testfile="$2"; shift;;
        -h|--help) show_help=true;;
        -ni|--noinstall) no_install_requirements=true;;
        -nv|--novirtualenv) no_virtualenv=true;;
        --update) do_update=true;;
        --no-update) no_update=true;;
        -pe|--python) PYTHON_EXE="$2"; shift;;
        --strict) fail_strict=true;;
        --generate-rc-file) generate_rc_file=true;;
        *) test_exit 1 "Unknown option '$1'. Run program with -h or --help for help.";;
    esac
    shift
done

if [[ -n ${show_help+x} ]]; then
    echo -e "Sanity testing script. If no tool is selected, all will run by default.\n"
    echo -e "Run as:\n  $0 [options]\n\nPossible options are:"
    echo -e "  -h, --help: Displays this help.\n"
    echo -e "Will run only selected tools:"
    echo -e "  -p, --pylint: Run PyLint."
    [[ ${ENABLE_TYPES} == true ]] && echo -e "  -t, --types: Run Mypy for checking types usage."
    [[ ${ENABLE_DOCTESTS} == true ]] && echo -e "  -d, --doctests: Run doctests with Nose."
    [[ ${ENABLE_UNITTESTS} == true ]] && echo -e "  -u, --unittests: Run unit tests with Nose."
    [[ ${ENABLE_COVERAGE} == true ]] && echo -e "  -c, --coverage: Run coverage tests."
    [[ ${ENABLE_BDD} == true ]] && echo -e "  -b, --bdd: Run BDD tests with Behave."
    [[ ${ENABLE_TODOS} == true ]] && echo -e "  --todo: Run check of TODOs."
    [[ ${ENABLE_SONAR} == true ]] && echo -e "  -s, --sonar: Send results into SonarQube.\n"
    echo -e "Will run run everything but selected tools:"
    echo -e "  -np, --no-pylint: Do not run PyLint."
    [[ ${ENABLE_TYPES} == true ]] && echo -e "  -nt, --no-types: Do not run Mypy for checking types usage."
    [[ ${ENABLE_DOCTESTS} == true ]] && echo -e "  -nd, --no-doctests: Do not run doctests with Nose."
    [[ ${ENABLE_UNITTESTS} == true ]] && echo -e "  -nu, --no-unittests: Do not run unit tests with Nose."
    [[ ${ENABLE_COVERAGE} == true ]] && echo -e "  -nc, --no-coverage: Do not run coverage tests."
    [[ ${ENABLE_BDD} == true ]] && echo -e "  -nb, --no-bdd: Do not run BDD tests with Behave."
    [[ ${ENABLE_TODOS} == true ]] && echo -e "  --no-todo: Do not run check of TODOs."
    [[ ${ENABLE_SONAR} == true ]] && echo -e "  -ns, --no-sonar: Do not send results into SonarQube.\n"
    echo -e "  -f: Run PyLint and MyPy only on selected file. Sonar will always run on all.\n"
    echo -e "  -tf: Run Nose only on selected files. Sonar will always run on all.\n"
    [[ ${ENABLE_COVERAGE} == true ]] && echo -e "  -o, --browser: Open coverage results in browser."
    echo -e "  -ni, --noinstall: Do not install requirements and dependencies.\n"
    echo -e "  -nv, --novirtualenv: Do not create/use virtualenv."
    echo -e "  --update: Only update team related files, then exit."
    echo -e "  --no-update: Don't update team related files."
    echo -e "  -pe, --python: Specify python executable to use for virtualenv."
    echo -e "  --strict: If used, exit code will be non-zero if any test fails. Otherwise only if SonarQube quality gate fails."
    echo -e "  --generate-rc-file: Generate RC file for this test script. This file allows to override default settings."
    exit 255
fi

# Sets default values to switches
# $1 = value to set
set_default_values() {
    local default=$1
    use_pylint=${use_pylint:-${default}}
    use_typecheck=${use_typecheck:-${default}}
    use_doctests=${use_doctests:-${default}}
    use_unittests=${use_unittests:-${default}}
    use_coverage=${use_coverage:-${default}}
    use_bdd=${use_bdd:-${default}}
    use_todos=${use_todos:-${default}}
    use_sonar=${use_sonar:-${default}}
}

# set everything to true by default, leave only explicitly disabled as false
if [[ ${use_pylint:-false} == false && ${use_typecheck:-false} == false && \
      ${use_unittests:-false} == false && ${use_coverage:-false} == false && \
      ${use_bdd:-false} == false && ${use_sonar:-false} == false && \
      ${use_doctests:-false} == false && ${use_todos:-false} == false ]]
then
    set_default_values true
else # only some tests selected, set the rest to false if not defined
    set_default_values false
fi

# turn off disabled
[[ ${ENABLE_TYPES} == false ]] && use_typecheck=false
[[ ${ENABLE_DOCTESTS} == false ]] && use_doctests=false
[[ ${ENABLE_UNITTESTS} == false ]] && use_unittests=false
[[ ${ENABLE_COVERAGE} == false ]] && use_coverage=false
[[ ${ENABLE_BDD} == false ]] && use_bdd=false
[[ ${ENABLE_TODOS} == false ]] && use_todos=false
[[ ${ENABLE_SONAR} == false ]] && use_sonar=false

open_in_browser=${open_in_browser:-false}
no_install_requirements=${no_install_requirements:-false}
no_virtualenv=${no_virtualenv:-false}
do_update=${do_update:-false}
no_update=${no_update:-false}
use_nose=false; ${use_doctests} || ${use_unittests} && use_nose=true
generate_rc_file=${generate_rc_file:-false}

source_files=$(find "${use_file:-${SOURCES_FOLDER}}" -name "*.py" ! -regex "\.\/\.venv_.*" 2>/dev/null)
unit_test_files=$(find "${use_testfile:-${UNIT_TESTS_FOLDER}}" -name "*.py" ! -regex "\.\/\.venv_.*" 2>/dev/null)
bdd_test_files=$(find "${use_testfile:-${BDD_TESTS_FOLDER}}" -name "*.py" ! -regex "\.\/\.venv_.*" 2>/dev/null)

if [[ ${generate_rc_file} == true ]]; then
    echo -e "# Uncomment only lines you need to change.\n" >${TEST_RC_FILE}

    head -n ${TEST_RC_FILE_HEAD_OFFSET["end"]} $0 | \
    tail -n +${TEST_RC_FILE_HEAD_OFFSET["start"]} | \
    sed 's/\(..*\)/#\1/' \
    >>${TEST_RC_FILE}

    echo "Test RC file generated into '${TEST_RC_FILE}'."
    exit 0
fi

if [[ ${no_update} == false && -n ${GITHUB_UPDATE_PERSONAL_ACCESS_TOKEN} && ${#GITHUB_UPDATE_SOURCES_TARGETS[@]} -gt 0 ]]; then
    echo -e "\n============================ Updating team files ==============================\n"

    for source_file in "${!GITHUB_UPDATE_SOURCES_TARGETS[@]}"; do
        url="${GITHUB_UPDATE_BASE_URL}/${source_file}"
        target_file="${GITHUB_UPDATE_SOURCES_TARGETS[${source_file}]}"
        target_path="$(dirname "${target_file}")"
        success_msg="File '${target_file}' updated."
        fail_msg="File '$source_file' from '${GITHUB_UPDATE_REPOSITORY}' repository could not be updated.\nCheck error output above."
        downloaded_file=$(mktemp)

        # Download is faster than checking if file has been modified via API
        curl_output=$(curl --fail -o "${downloaded_file}" "${url}" 2>&1)
        test_exit $? "${curl_output}\n\n${fail_msg}" "${success_msg}"

        mkdir -p "${target_path}"
        mv "${downloaded_file}" "${target_file}"
    done

    [[ ${do_update} == true ]] && exit 0
fi

if [[ ${no_virtualenv} == false ]]; then
    if [[ ! -d "${VENV}" ]]; then
        check_supported_python_version

        echo -e "\n============================ Creating virtualenv ==============================\n"

        if ! ${PYTHON_EXE} -m virtualenv --version >/dev/null 2>&1; then
            ${PYTHON_EXE} -m pip install --user --upgrade virtualenv
            test_exit $? "Could not install virtualenv via pip."
        fi

        ${PYTHON_EXE} --version >/dev/null 2>&1
        test_exit $? "Python executable '${PYTHON_EXE}' does not exist. Cannot create virtualenv."

        ${PYTHON_EXE} -m virtualenv -p "${PYTHON_EXE}" "${VENV}"
    fi

    source "${VENV_ACTIVATE}"
    test_exit $? "Failed to activate virtualenv."

    PIP_EXE="$(discover_pip)"
else
    check_supported_python_version
fi

# Install given libraries if condition variable is true
# $1 = condition variable
# $@ = library names
pip_install_if () {
    [[ $1 == false ]] && return 1
    shift
    ${PIP_EXE} install --upgrade $@
    test_exit $? "Failed to install required dependencies via pip."
}

if [[ ${no_install_requirements} == false ]]; then
    echo -e "\n========================== Refreshing dependencies ============================\n"
    pip_install_if true pylint
    pip_install_if ${ENABLE_TYPES} mypy
    pip_install_if ${ENABLE_NOSE} nose rednose
    pip_install_if ${ENABLE_UNITTESTS} nose-timer
    pip_install_if ${ENABLE_BDD} behave
    pip_install_if ${ENABLE_COVERAGE} coverage

    if [[ "${CURRENT_OS}" =~ (CYGWIN|MINGW).* ]]; then
        ${PIP_EXE} install --upgrade pypiwin32
        test_exit $? "Failed to install pypiwin32 via pip."
    fi

    for requirements_file_name in requirements*.txt; do
        if [[ -f "${requirements_file_name}" ]]; then
            ${PIP_EXE} install --upgrade -r "${requirements_file_name}"
            test_exit $? "Failed to install requirements via pip from '${requirements_file_name}'."
        fi
    done

    echo -e "\nUse '-ni' command line argument to prevent installing requirements."
fi

if [[ ${use_bdd} == true ]]; then
    echo -e "\n============================== Running behave =================================\n"

    behave ${BDD_TESTS_FOLDER}

    test_failed $? "Behave BDD tests"
fi

if [[ ${ENABLE_NOSE} == true && ${use_nose} == true ]]; then
    echo -e "\n============================= Running nose test ===============================\n"

    params=(--hide-skips --rednose -s)
    [[ ${use_unittests} == true ]] && params+=(--with-timer --timer-ok 250ms --timer-warning 1s --timer-filter warning,error)
    [[ ${use_sonar} == true ]] && params+=(--with-xunit --cover-xml)
    [[ ${use_doctests} == true ]] && params+=(--with-doctest --doctest-options='+ELLIPSIS,+NORMALIZE_WHITESPACE')

    nosetests ${params[@]} ${UNIT_TESTS_FOLDER}/*

    test_failed $? "\nNosetests"
fi

if [[ ${ENABLE_COVERAGE} == true && ${use_coverage} == true ]]; then
    echo -e "\n=========================== Running coverage test =============================\n"

    coverage run --branch --source="${SOURCES_FOLDER}" -m unittest discover -q -s "${UNIT_TESTS_FOLDER}"
    coverage report --skip-covered --fail-under=${COVERAGE_MIN_PERCENTAGE:-0}

    test_failed $? "\nTest for minimum coverage of ${COVERAGE_MIN_PERCENTAGE:-0}%"

    coverage html -d cover

    # open in default browser
    [[ ${open_in_browser} == true ]] && ${WEBSITE_OPENER} "${COVER_PATH}/cover/index.html"
fi

if [[ ${ENABLE_TYPES} == true && ${use_typecheck} == true ]]; then
    echo -e "\n============================ Running type check ===============================\n"

    mypy_exe="mypy"
    if [[ "${CURRENT_OS}" =~ (CYGWIN|MINGW).* ]]; then
        mypy_exe="${PYTHON_EXE} ${VENV}/Lib/site-packages/mypy/"
    fi

    # --disallow-untyped-calls
    ${mypy_exe} --ignore-missing-imports ${source_files} ${unit_test_files} ${bdd_test_files}
    test_failed $? "Type checks"
fi

# $1 = 'source', 'tests', 'sonar'
run_pylint() {
    # unused-import disabled because it is picking up typing imports. Fix is coming.

    msg_template='{C}:{line:3d},{column:2d}: {msg} ({symbol}, {msg_id})'
    params=()

    if [[ $1 == 'source' ]]; then  # running pylint for source code
        export PYLINTRC="${SOURCES_FOLDER}/.pylintrc"
        files=${source_files}
    elif [[ $1 == 'tests' ]]; then  # running pylint for tests code
        export PYLINTRC="${TESTS_FOLDER}/.pylintrc"
        params=(--disable=protected-access)
        files="${unit_test_files} ${bdd_test_files}"
    elif [[ $1 == 'sonar' ]]; then  # running pylint for SonarQube
        params=(--reports=n --output-format=text)
        msg_template='{path}:{line}: [{msg_id}({symbol}), {obj}] {msg}'
        files="${source_files} ${unit_test_files} ${bdd_test_files}"
    else  # invalid option
        test_exit 1 "Invalid pylint run type '$1'."
    fi

    pylint --disable="all,RP0001,RP0002,RP0003,RP0101,RP0401,RP0701,RP0801" \
        --enable="F,E,W,R,C" --msg-template="${msg_template}" \
        --disable='
        missing-docstring,
        missing-type-doc,
        missing-returns-doc,
        missing-return-type-doc,
        missing-yield-doc,
        missing-yield-type-doc,

        unused-import,

        apply-builtin,
        backtick,
        basestring-builtin,
        buffer-builtin,
        cmp-builtin,
        cmp-method,
        coerce-builtin,
        coerce-method,
        delslice-method,
        dict-iter-method,
        dict-view-method,
        execfile-builtin,
        file-builtin,
        filter-builtin-not-iterating,
        getslice-method,
        hex-method,
        import-star-module-level,
        indexing-exception,
        input-builtin,
        intern-builtin,
        long-builtin,
        long-suffix,
        map-builtin-not-iterating,
        metaclass-assignment,
        next-method-called,
        no-absolute-import,
        nonzero-method,
        oct-method,
        old-division,
        old-ne-operator,
        old-octal-literal,
        old-raise-syntax,
        parameter-unpacking,
        print-statement,
        raising-string,
        range-builtin-not-iterating,
        raw_input-builtin,
        reduce-builtin,
        reload-builtin,
        round-builtin,
        setslice-method,
        standarderror-builtin,
        unichr-builtin,
        unicode-builtin,
        unpacking-in-except,
        using-cmp-argument,
        xrange-builtin,
        zip-builtin-not-iterating
        ' \
        --evaluation="10.0 - ((float(20 * fatal + 10 * error + 5 * warning + 2 * refactor + convention) / statement) * 10)" \
        ${params[@]} --enable='suppressed-message,useless-suppression' ${files}

    return $?
}

if [[ ${use_pylint} == true ]]; then
    if [[ "${CURRENT_OS}" =~ (CYGWIN|MINGW).* ]]; then
        # color fix for windows terminals
        export TERM=xterm-16color
    fi

    if [[ -n "${source_files}" ]]; then
        echo -e "\n====================== Running pylint on source code ==========================\n"

        run_pylint 'source'
        test_failed $? "PyLint checks on source code"
    fi

    if [[ -n "${unit_test_files}" || -n "${bdd_test_files}" ]]; then
        echo -e "\n========================== Running pylint on tests ============================\n"

        run_pylint 'tests'
        test_failed $? "PyLint checks on tests" "\n"
    fi
fi

if [[ ${use_todos} == true ]]; then
    echo -e "\n=========================== Running TODOs check ===============================\n"

    todos="$(grep -Enr 'TODO *[(:]' ${SOURCES_FOLDER} ${TESTS_FOLDER} | tr -s ' ')"
    unnamed_todos=$(echo "${todos}" | grep -E "TODO[^(]*:")
    named_todos=$(echo "${todos}" | grep -E "TODO *\([^)]*\):")
    name_counts="$(echo "${named_todos}" | sed 's/.*TODO *(\([^)]*\)).*/\1/' |
                   tr '[:upper:]' '[:lower:]' | sort | uniq -c |
                   awk '{print toupper(substr($2,0,1))tolower(substr($2,2))": "$1}')"
    ok_todos="$(echo "${name_counts}" | awk -v limit=${TODOS_LIMIT_PER_PERSON} '$2 <= limit{print $0}')"
    too_many_todos="$(echo "${name_counts}" | awk -v limit=${TODOS_LIMIT_PER_PERSON} '$2 > limit{print $0}')"

    [[ $(echo "${named_todos}" | wc -c) -gt 1 ]] && echo -e "All named TODOs:\n\n${named_todos}"

    if [[ $(echo "${unnamed_todos}" | wc -c) -gt 1 ]]; then
        echo -e "\nUnnamed TODOs:\n\n${unnamed_todos}\n"
        test_failed 1 "All TODOs must be named (# TODO(<name>): <comment>). Test"
    fi

    [[ $(echo "${named_todos}" | wc -c) -gt 1 ]] && echo -e "\nTODO counts per person (maximum is ${TODOS_LIMIT_PER_PERSON}):\n\n${ok_todos}\n"

    if [[ $(echo "${too_many_todos}" | wc -c) -gt 1 ]]; then
        echo -e "Too many TODOs per person (maximum is ${TODOS_LIMIT_PER_PERSON}):\n\n${too_many_todos}\n"
        test_failed 1 "Every person must have at most ${TODOS_LIMIT_PER_PERSON} TODOs. Test"
    fi
fi

# Reads value from a JSON formatted file
# $1 = file name of JSON file to read
# $2 = key to read (in form of python dict key, such as ['section']['value']
# $3 = name of the value to print in case of an error
read_json() {
    local value="$(${PYTHON_EXE} -c "import json; print(json.loads(open('$1').read())$2, end='')")"
    test_exit $? "Unable to read $3."
    echo "${value}"
}

# Waits for SonarQube report and returns 0 if quality gate passes or 1 if not
# $1 = url of the SonarQube report
check_sonar_report() {
    local report_url="$1"
    local username="$(sed -n -e 's/^\s*sonar\.login\s*=\s*//p' ${SONAR_FILE})"
    local password="$(sed -n -e 's/^\s*sonar\.password\s*=\s*//p' ${SONAR_FILE})"
    local server="$(sed -n -e 's/^\s*sonar\.host\.url\s*=\s*//p' ${SONAR_FILE})"
    local status='IN_PROGRESS'
    echo "Report status URL: ${report_url}"

    echo -n "Waiting for status report"
    while [[ "${status}" == 'IN_PROGRESS' || "${status}" == 'PENDING' ]]; do
        output="$(curl -u "${username}:${password}" -v -o "${SONAR_REPORT}" "${report_url}" 2>&1)"
        test_exit $? "\n${output}\nUnable to fetch status of SonarQube analysis."
        status="$(read_json "${SONAR_REPORT}" "['task']['status']" 'status of SonarQube analysis')"
        echo -n "."
        sleep 1
    done
    echo -e " ${GREEN}Done${NC}."

    analysisId="$(read_json "${SONAR_REPORT}" "['task']['analysisId']" 'analysis ID')"
    report_url="${server}/api/qualitygates/project_status?analysisId=${analysisId}"
    echo "Quality gate status URL: ${report_url}"
    echo -n "Checking SonarQube quality gate..."
    output="$(curl -u "${username}:${password}" -v -o "${SONAR_REPORT}" "${report_url}" 2>&1)"
    test_exit $? "\n${output}\nUnable to fetch SonarQube quality gate result."
    echo -e " ${GREEN}Done${NC}."

    status="$(read_json "${SONAR_REPORT}" "['projectStatus']['status']" 'project status')"
    if [[ "${status}" == 'ERROR' ]]; then
        return 1
    else
        return 0
    fi
}

if [[ ${ENABLE_SONAR} == true && ${use_sonar} == true ]]; then
    echo -e "\n============================= Running SonarLint ===============================\n"

    if [[ ! -f "${SONAR_SCANNER}" ]]; then
        curl -L -s -o "${SONAR_SCANNER_ZIP_FILE}" "${SONAR_SCANNER_URL}"
        test_exit $? "Failed to download sonar-scanner."  "Sonar-scanner downloaded."
        unzip -q -o "${SONAR_SCANNER_ZIP_FILE}"
        test_exit $? "Failed to unzip scanner.zip"  "Sonar-scanner unzipped."
        mkdir "${VENV}" 2>/dev/null
        cp -f -R "${SONAR_SCANNER_ZIP_FOLDER}/bin" "${SONAR_SCANNER_ZIP_FOLDER}/lib" "${VENV}"
        chmod +x "${SONAR_SCANNER}"
    fi

    msg="Could run 'sonar-scanner'. Make sure you have Java JDK installed."
    output="$(${SONAR_SCANNER} --version 2>&1)"
    test_exit $? "${output}\n\n${msg}"

    if [[ ! -f "${SONAR_FILE}" ]]; then
        echo -n "Enter your SonarQube token (My Account/Security/Tokens): "
        read sonar_token
        echo -e "\nWriting information into '${SONAR_FILE}'."
        sonar_project_no_spaces="$(echo "${SONAR_PROJECT}" | tr ' ' '_')"

        echo "sonar.scm.disabled=true
sonar.python.coverage.reportPath=${COVERAGE_FILE}
sonar.python.xunit.reportPath=${XUNIT_FILE}
sonar.python.pylint.reportPath=${PYLINT_REPORT}
sonar.host.url=${SONAR_SERVER}
sonar.projectKey=${SONAR_TEAM}:${sonar_project_no_spaces}
sonar.projectName=${SONAR_PROJECT}
sonar.projectVersion=${SONAR_PROJECT_VERSION}
sonar.sources=.
sonar.coverage.exclusions=cover/**,${UNIT_TESTS_FOLDER}/**,${BDD_TESTS_FOLDER}/**
sonar.inclusions=${SOURCES_FOLDER}/**
sonar.login=${sonar_token}" >"${SONAR_FILE}"
    fi

    if [[ ! -f "${PYLINT_REPORT}" ]]; then
        echo -n "Running PyLint... "
        run_pylint 'sonar' >"${PYLINT_REPORT}"
        echo -e "${GREEN}Done${NC}."
    fi

    if [[ ! -f "${XUNIT_FILE}" ]]; then
        echo -n "Running unit tests ... "
        nosetests --xunit-file= --with-xunit -q $(find "${UNIT_TESTS_FOLDER}" -name "*.py") >/dev/null 2>&1
        echo -e "${GREEN}Done${NC}."
    fi

    if [[ ! -f "${COVERAGE_FILE}" ]]; then
        # Output from nosetest has different paths than from coverage directly
        # and SonarQube does not parse the nosetest output correctly :(
        echo -n "Running coverage ... "
        coverage run --branch --source="${SOURCES_FOLDER}" -m unittest $(find "${UNIT_TESTS_FOLDER}" -name "*.py") >/dev/null 2>&1
        coverage xml -i -o "${COVERAGE_FILE}"
        echo -e "${GREEN}Done${NC}."
    fi

    echo -n "Sending results to SonarQube server... "
    output="$(${SONAR_SCANNER} 2>&1)"
    test_exit $? "${output}"
    echo -e "${GREEN}Done${NC}."
    echo "${output}" | grep "ANALYSIS SUCCESSFUL" | sed 's/INFO: //'

    report_url="$(echo "${output}" | grep "More about the report processing" | sed -E 's|.*(https?://.*id=[-a-zA-Z0-9_]+).*|\1|')"
    check_sonar_report "${report_url}"
    test_failed_strict $? "SonarQube quality gate"

    mkdir -p dist
    cp "${XUNIT_FILE}" "dist/${XUNIT_FILE}"
fi

if [[ ${no_virtualenv} == false ]]; then
    deactivate
fi

cleanup

if [[ ${failed} -ne 0 ]]; then
    echo -e "\n${BRED}Some tests failed.${NC}"
else
    echo -e "\n${BGREEN}All tests passed.${NC}"
fi

exit ${result_code}