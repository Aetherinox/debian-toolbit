#!/bin/bash
PATH="/bin:/usr/bin:/sbin:/usr/sbin"
echo 

##--------------------------------------------------------------------------
#   load secrets file to handle Github rate limiting via a PAF.
#   managed via https://github.com/settings/tokens?type=beta
##--------------------------------------------------------------------------

if [ -f secrets.sh ]; then
. ./secrets.sh
fi

##--------------------------------------------------------------------------
#   vars
##--------------------------------------------------------------------------

app_title="htpasswd"
app_author="Aetherinox"
app_ver=("1" "0" "0" "0")
app_repo="debian-toolkit"
app_repo_branch="main"
app_repo_url="https://github.com/${app_author}/${app_repo}"
app_mnfst="https://raw.githubusercontent.com/${app_author}/${app_repo}/${app_repo_branch}/manifest.json"

##--------------------------------------------------------------------------
#   exports
##--------------------------------------------------------------------------

export DATE=$(date '+%Y%m%d')
export YEAR=$(date +'%Y')
export TIME=$(date '+%H:%M:%S')
export ARGS=$1
export LOGS_DIR="/var/log/htpasswd"
export LOGS_FILE="$LOGS_DIR/htpasswd-${DATE}.log"
export HTPASSWD_FILE="/etc/htpasswd.d"
export SECONDS=0

##--------------------------------------------------------------------------
#   vars > colors for whiptail
##--------------------------------------------------------------------------

export NEWT_COLORS='
root=,black
window=,lightgray
shadow=,
title=color8,
checkbox=,magenta
entry=,color8
label=blue,
actlistbox=,magenta
actsellistbox=,magenta
helpline=,magenta
roottext=,magenta
emptyscale=magenta
disabledentry=magenta,
'

##--------------------------------------------------------------------------
#   vars > colors
#
#   tput setab  [1-7]       – Set a background color using ANSI escape
#   tput setb   [1-7]       – Set a background color
#   tput setaf  [1-7]       – Set a foreground color using ANSI escape
#   tput setf   [1-7]       – Set a foreground color
##--------------------------------------------------------------------------

BLACK=$(tput setaf 0)
RED=$(tput setaf 1)
ORANGE=$(tput setaf 208)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 156)
LIME_YELLOW=$(tput setaf 190)
POWDER_BLUE=$(tput setaf 153)
BLUE=$(tput setaf 033)
MAGENTA=$(tput setaf 5)
CYAN=$(tput setaf 6)
WHITE=$(tput setaf 7)
GREYL=$(tput setaf 242)
DEV=$(tput setaf 157)
DEVGREY=$(tput setaf 243)
FUCHSIA=$(tput setaf 198)
PINK=$(tput setaf 200)
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
BLINK=$(tput blink)
REVERSE=$(tput smso)
UNDERLINE=$(tput smul)

##--------------------------------------------------------------------------
#   vars > status messages
##--------------------------------------------------------------------------

STATUS_MISS="${BOLD}${GREYL} MISS ${NORMAL}"
STATUS_SKIP="${BOLD}${GREYL} SKIP ${NORMAL}"
STATUS_OK="${BOLD}${GREEN}  OK  ${NORMAL}"
STATUS_NEW="${BOLD}${GREEN} +NEW ${NORMAL}"
STATUS_FAIL="${BOLD}${RED} FAIL ${NORMAL}"
STATUS_HALT="${BOLD}${YELLOW} HALT ${NORMAL}"

##--------------------------------------------------------------------------
#   func > get version
#
#   returns current version of app
#   converts to human string.
#       e.g.    "1" "2" "4" "0"
#               1.2.4.0
##--------------------------------------------------------------------------

get_version()
{
    ver_join=${app_ver[*]}
    ver_str=${ver_join// /.}
    echo ${ver_str}
}

##--------------------------------------------------------------------------
#   func > version > compare greater than
#
#   this function compares two versions and determines if an update may
#   be available. or the user is running a lesser version of a program.
##--------------------------------------------------------------------------

get_version_compare_gt()
{
    test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1";
}

##--------------------------------------------------------------------------
#   package exists
#
#   returns if package exists at all to download or not
##--------------------------------------------------------------------------

function package_exists()
{
    dpkg -l "$1" &> /dev/null
    return $?
}

##--------------------------------------------------------------------------
#   vars > active repo branch
##--------------------------------------------------------------------------

app_repo_branch_sel=$( [[ -n "$OPT_BRANCH" ]] && echo "$OPT_BRANCH" || echo "$app_repo_branch"  )

##--------------------------------------------------------------------------
#   func > logs > begin
##--------------------------------------------------------------------------

Logs_Begin()
{
    if [ $OPT_NOLOG ] ; then
        echo
        echo
        echo "${TIME} | Logging for this manager has been disabled." >> ${LOGS_FILE}
        echo
        echo
        sleep 3
    else
        if [ ! -d $LOGS_DIR ]; then mkdir -p $LOGS_DIR; fi

        LOGS_PIPE=${LOGS_FILE}.pipe

        if ! [[ -p $LOGS_PIPE ]]; then
            mkfifo -m 775 $LOGS_PIPE
            echo "${TIME} | Creating Pipe: ${LOGS_PIPE}" >> ${LOGS_FILE}
        fi

        LOGS_OBJ=${LOGS_FILE}
        exec 3>&1
        tee -a ${LOGS_OBJ} <$LOGS_PIPE >&3 &
        app_pid_tee=$!
        exec 1>$LOGS_PIPE
        PIPE_OPENED=1
    fi
}

##--------------------------------------------------------------------------
#   func > logs > finish
##--------------------------------------------------------------------------

Logs_Finish()
{
    if [ ${PIPE_OPENED} ] ; then
        exec 1<&3
        sleep 0.2
        ps --pid $app_pid_tee >/dev/null
        local pipe_status=$?
        if [ $pipe_status -eq 0 ] ; then
            # using $(wait $app_pid_tee) would be better
            # however, some commands leave file descriptors open
            sleep 1
            kill $app_pid_tee >> $LOGS_FILE 2>&1
        fi

        echo "${TIME} | Destroying Pipe: ${LOGS_PIPE} (${app_pid_tee})" >> ${log}

        rm $LOGS_PIPE
        unset PIPE_OPENED
    fi

    duration=$SECONDS
    elapsed="$(($duration / 60)) minutes and $(($duration % 60)) seconds elapsed."

    echo "${TIME} | USER: Exit | Elapsed: ${elapsed}" >> ${log} 2>&1
}

##--------------------------------------------------------------------------
#   Quit App
##--------------------------------------------------------------------------

App_Quit()
{
    Logs_Finish
    exit 0
    sleep 0.2
}

##--------------------------------------------------------------------------
#   Begin Logging
##--------------------------------------------------------------------------

Logs_Begin

##--------------------------------------------------------------------------
#   Require sudo
##--------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "htpasswd requires root. su or sudo -s and run again."
    App_Quit
fi

##--------------------------------------------------------------------------
#   x86_64
##--------------------------------------------------------------------------

if [[ ! $(uname -m) == "x86_64" ]]; then
    echo -e "\033[0;31mUnsupported architecture ($(uname -m)) detected! \033[0m"
    echo
    read -rep 'By pressing enter to continue, you agree to the above statement. Press control-c to quit.'
fi

##--------------------------------------------------------------------------
#   Post Init
##--------------------------------------------------------------------------

function Action_Complete
{
    echo
    echo -e " ${BLUE}-------------------------------------------------------------------------${NORMAL}"
    echo
    echo -e "  ${NORMAL}htpasswd has been created"
    echo -e "  ${NORMAL}      user:  ${YELLOW}${user}${NORMAL}"
    echo -e "  ${NORMAL}      pass:  ${YELLOW}${pass}${NORMAL}"
    echo
    echo -e "  ${NORMAL}Credentials stored in:${NORMAL}"
    echo -e "  ${NORMAL}      ${YELLOW}${HTPASSWD_FILE}/htpasswd.${user}"
    echo
    echo -e " ${BLUE}-------------------------------------------------------------------------${NORMAL}"
    echo
}

##--------------------------------------------------------------------------
#   Manage User
##--------------------------------------------------------------------------

function Action_ManageUser()
{

   whiptail --title "htpasswd Setup" --msgbox "A .htpasswd file is typically used when protecting a file, folder, or entire website with a password using HTTP authentication and implemented using rules within the .htaccess file. User credentials are stored on separate lines, with each line containing a username and password separated by a colon (:). Usernames are stored in plain text but passwords are stored in an encrypted hashed format.\n\nThis script will auto-generate an htpasswd file which can be utilized for your web server.\n\nYour new htpasswd file will be stored in ${HTPASSWD_FILE}" 15 80

    while [[ -z $user ]]; do
        user=$( whiptail --inputbox "Enter Username" 9 50 3>&1 1>&2 2>&3 );
        exitstatus=$?;

        if [ "$exitstatus" = 1 ]; then 
            App_Quit
        fi

        if [[ $user =~ [A-Z] ]]; then
            read -n 1 -s -r -p "Usernames must not contain capital letters. Press enter to try again."
            printf "\n"
            user=
        fi
    done

    while [[ -z "${pass}" ]]; do
        pass=$( whiptail --inputbox "Enter User password. Leave empty to generate." 9 50 3>&1 1>&2 2>&3 )
        exitstatus=$?

        if [ "$exitstatus" = 1 ]; then
            App_Quit
        fi

        if [[ -z "${pass}" ]]; then
            pass="$( head /dev/urandom | tr -dc A-Za-z0-9 | head -c16 )"
        fi

        if [[ -n $( which cracklib-check ) ]]; then
            printf '%-57s' "  Cracklib Detected"
            echo

            echo -n ${GREYL}
            printf '%-57s' "    |--- Password Strength Check"
            echo -n ${NORMAL}

            sleep 1

            str="$( cracklib-check <<<"$pass" )"
            check=$( grep OK <<<"$str" )

            if [[ -z $check ]]; then
                echo -e "[ ${STATUS_FAIL} ]"
                echo
                sleep 1
                echo -e "  ${NORMAL}Password not strong enough. Press any key to try another password"
                sleep 0.5
                read -n 1 -s -r -p ""
                printf "\n"
                pass=
            else
                echo -e "[ ${STATUS_OK} ]"
            fi

        fi
    done

    echo "$user:$pass" > /root/.master.info

    # require htpasswd
    printf '%-57s' "  Locating Lib htpasswd"
    echo
    if ! [ -x "$( command -v htpasswd )" ]; then
        bMissingHtpasswd=true
    fi

    if [ "$bMissingHtpasswd" = true ]; then
        echo -n ${GREYL}
        printf '%-57s' "    |--- Installing"
        echo -n ${NORMAL}

        apt-get -q -y install apache2-utils >> ${log} 2>&1
        echo -e "[ ${STATUS_OK} ]"
    else
        where_htpasswd=$( which htpasswd )

        echo -n ${GREYL}
        printf '%-57s' "    |--- Path $where_htpasswd"
        echo -n ${NORMAL}

        if [[ -n $where_htpasswd ]]; then
            echo -e "[ ${STATUS_OK} ]"
        else
            echo -e "[ ${STATUS_FAIL} ]"
        fi
    fi

    ##--------------------------------------------------------------------------
    #   htpasswd options
    #   
    #       -c  Create a new file.
    #       -n  Don't update file; display results on stdout.
    #       -b  Use the password from the command line rather than prompting for it.
    #       -i  Read password from stdin without verification (for script usage).
    #       -m  Force MD5 encryption of the password (default).
    #       -B  Force bcrypt encryption of the password (very secure).
    #       -C  Set the computing time used for the bcrypt algorithm
    #           (higher is more secure but slower, default: 5, valid: 4 to 17).
    #       -d  Force CRYPT encryption of the password (8 chars max, insecure).
    #       -s  Force SHA encryption of the password (insecure).
    #       -p  Do not encrypt the password (plaintext, insecure).
    #       -D  Delete the specified user.
    #       -v  Verify password for the specified user.
    ##--------------------------------------------------------------------------

    printf '%-57s' "  Checking /home/$user"
    echo

    if [[ -d /home/"$user" ]]; then
        echo -n ${GREYL}
        printf '%-57s' "    |--- Existing Found"
        echo -n ${NORMAL}

        echo -e "[ ${STATUS_OK} ]"

        #   chpasswd<<<"${user}:${pass}"

        htpasswd -b -B /etc/htpasswd $user $pass >> /dev/null 2>&1
        mkdir -p ${HTPASSWD_FILE}

        sleep 0.5

        printf '%-57s' "  Adding Password for ${user}"
        echo

        echo -n ${GREYL}
        printf '%-57s' "    |--- ${pass}"
        echo -n ${NORMAL}

        htpasswd -b -B -c ${HTPASSWD_FILE}/htpasswd.${user} $user $pass >> /dev/null 2>&1
        echo -e "[ ${STATUS_OK} ]"
        
        chown -R $user:$user /home/${user}
    else
        printf '%-57s' "    |--- Creating Folder"
        echo -e "[ ${STATUS_OK} ]"

        #   useradd "${user}" -m -G www-data -s /bin/bash
        #   chpasswd<<<"${user}:${pass}"
    
        htpasswd -b -B /etc/htpasswd $user $pass >> /dev/null 2>&1
        mkdir -p ${HTPASSWD_FILE}

        sleep 0.5

        echo
        printf '%-57s' "  Adding Password for ${user}"
        htpasswd -b -B -c ${HTPASSWD_FILE}/htpasswd.${user} $user $pass >> /dev/null 2>&1
        echo -e "[ ${STATUS_OK} ]"
    fi

    #chmod 750 /home/${user}

    Action_Complete

}

##--------------------------------------------------------------------------
#   Post Inst
##--------------------------------------------------------------------------

Preinit()
{
    export log=${LOGS_FILE}

    clear

    sleep 0.3

    echo -e " ${BLUE}-------------------------------------------------------------------------${NORMAL}"
    echo -e " ${GREEN}${BOLD} ${app_title} - v$(get_version)${NORMAL}${MAGENTA}"
    echo
    echo -e "  This package allows you to create an htpasswd file which can be used"
    echo -e "  to authenticate users via your webserver."
    echo

    apt-get -y -qq update >> ${log} 2>&1
    apt-get -y -qq install lsb-release >> ${log} 2>&1

    distribution=$(lsb_release -is)
    release=$(lsb_release -rs)
    codename=$(lsb_release -cs)

    echo -e "  ${BOLD}${GREEN}Distribution:         ${NORMAL}${distribution}"
    echo -e "  ${BOLD}${GREEN}Release:              ${NORMAL}${release}"
    echo -e "  ${BOLD}${GREEN}Codename:             ${NORMAL}${codename}"

    echo -e " ${BLUE}-------------------------------------------------------------------------${NORMAL}"
    echo

    if [[ ! $distribution =~ ("Debian"|"Ubuntu"|"Zorin") ]]; then
        echo -e "  ${ORANGE}Error${WHITE}"
        echo -e "  "
        echo -e "  ${WHITE}${distribution} not supported. ${app_title} requires Ubuntu, Debian, or ZorinOS.${NORMAL}"

        App_Quit
    fi

    if [[ ! $codename =~ ("xenial"|"bionic"|"jessie"|"stretch"|"buster"|"jammy"|"lunar"|"focal") ]]; then
        echo -e "  ${ORANGE}Error${WHITE}"
        echo -e "  "
        echo -e "  ${WHITE}${codename} not supported.${NORMAL}"

        App_Quit
    fi

    echo -e "  ${NORMAL}Setting up dependencies"

    if [[ $distribution =~ ("Ubuntu"|"Zorin") ]]; then
        echo -n ${GREYL}
        printf '%-57s' "    |--- Checking repos"
        echo -n ${NORMAL}
        if [[ -z $( which add-apt-repository ) ]]; then
            apt-get install -y -q software-properties-common >> ${log} 2>&1
        fi
        sleep 0.5
        echo -e "[ ${STATUS_OK} ]"

        ##--------------------------------------------------------------------------
        #   add universe repo
        #
        #   Main            : Officially supported software.
        #   Restricted      : Supported software that is not available under a completely free license.
        #   Universe        : Community maintained software, i.e. not officially supported software.
        #   Multiverse      : Software that is not free.
        ##--------------------------------------------------------------------------

        checkUniverse=$( sudo add-apt-repository --list | grep -v "ports" | grep -E "$sys_code main.*universe|universe.*main" )

        if [ -z "$checkUniverse" ]; then
            printf '%-57s' "  Adding universe repos"

            add-apt-repository universe >> ${log} 2>&1
            add-apt-repository multiverse >> ${log} 2>&1
            add-apt-repository restricted -u >> ${log} 2>&1

            echo -e "[ ${STATUS_OK} ]"
        fi
    fi

    apt-get -q -y update >> ${log} 2>&1
    apt-get -q -y upgrade >> ${log} 2>&1
    apt-get -q -y install whiptail git sudo curl wget apache2-utils >> ${log} 2>&1

    Action_ManageUser
}

##--------------------------------------------------------------------------
#   Activate
##--------------------------------------------------------------------------

Preinit