#!/bin/bash
PATH="/bin:/usr/bin:/sbin:/usr/sbin"
echo 

##--------------------------------------------------------------------------
#   exports
##--------------------------------------------------------------------------

export DATE=$(date '+%Y%m%d')
export YEAR=$(date +'%Y')
export TIME=$(date '+%H:%M:%S')
export ARGS=$1
export LOGS_DIR="/var/log/htpasswd"
export LOGS_FILE="$LOGS_DIR/htpasswd-${DATE}.log"
export SECONDS=0

##--------------------------------------------------------------------------
#   load secrets file to handle Github rate limiting via a PAF.
#   managed via https://github.com/settings/tokens?type=beta
##--------------------------------------------------------------------------

if [ -f secrets.sh ]; then
. ./secrets.sh
fi

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

if [[ ! $(uname -m) == "x86_64" ]]; then
  echo -e "\033[0;31mUnsupported architecture ($(uname -m)) detected! \033[0m"
  echo
  read -rep 'By pressing enter to continue, you agree to the above statement. Press control-c to quit.'
fi

Preinit()
{
  export log=${LOGS_FILE}
  echo "Checking OS ... "
  apt-get -y -qq update >> ${log} 2>&1
  apt-get -y -qq install lsb-release >> ${log} 2>&1
  distribution=$(lsb_release -is)
  release=$(lsb_release -rs)
  codename=$(lsb_release -cs)
    if [[ ! $distribution =~ ("Debian"|"Ubuntu"|"Zorin") ]]; then
      echo "Distribution ($distribution) not supported. htpasswd requires Ubuntu, Debian, or ZorinOS."
      App_Quit
    fi
    if [[ ! $codename =~ ("xenial"|"bionic"|"jessie"|"stretch"|"buster"|"jammy"|"lunar"|"focal") ]]; then
      echo "Release ($codename) of $distribution is not supported."
      App_Quit
    fi
  echo "Running $distribution $release."
}

function Prepare()
{
  echo "Updating system and grabbing core dependencies."

  if [[ $distribution =~ ("Ubuntu"|"Zorin") ]]; then
    echo "Checking enabled repos"
    #if [[ -z $(which add-apt-repository) ]]; then
      #apt-get install -y -q software-properties-common >> ${log} 2>&1
    #fi
    #add-apt-repository universe >> ${log} 2>&1
    #add-apt-repository multiverse >> ${log} 2>&1
    # add-apt-repository restricted -u >> ${log} 2>&1
  fi
  apt-get -q -y update >> ${log} 2>&1
  apt-get -q -y upgrade >> ${log} 2>&1
  apt-get -q -y install whiptail git sudo curl wget >> ${log} 2>&1
}

function Start()
{
  whiptail --title "htpasswd Setup" --msgbox "This script will ask you to enter a username and password which will be used for your htpasswd file." 15 50
}

function Addusr()
{
    while [[ -z $user ]]; do
        user=$(whiptail --inputbox "Enter Username" 9 30 3>&1 1>&2 2>&3); exitstatus=$?;
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
        pass=$(whiptail --inputbox "Enter User password. Leave empty to generate." 9 30 3>&1 1>&2 2>&3)
        exitstatus=$?

        if [ "$exitstatus" = 1 ]; then
            App_Quit
        fi

        if [[ -z "${pass}" ]]; then
            pass="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c16)"
        fi

        if [[ -n $(which cracklib-check) ]]; then 
            echo "Cracklib detected. Checking password strength."
            sleep 1
            str="$(cracklib-check <<<"$pass")"
            check=$(grep OK <<<"$str")
            if [[ -z $check ]]; then
            read -n 1 -s -r -p "Password did not pass cracklib check. Press any key to enter a new password"
            printf "\n"
            pass=
            else
            echo "OK."
            fi
        fi
    done

    echo "$user:$pass" > /root/.master.info

    if [[ -d /home/"$user" ]]; then
        echo "User directory already exists ... "
        echo "Changing password to new password"
        #chpasswd<<<"${user}:${pass}"
        htpasswd -b -c /etc/htpasswd $user $pass
        mkdir -p /etc/htpasswd.d/
        htpasswd -b -c /etc/htpasswd.d/htpasswd.${user} $user $pass
        chown -R $user:$user /home/${user}
    else
        echo -e "Creating new user \e[1;95m$user\e[0m ... "
        useradd "${user}" -m -G www-data -s /bin/bash
        #chpasswd<<<"${user}:${pass}"
        htpasswd -b -c /etc/htpasswd $user $pass
        mkdir -p /etc/htpasswd.d/
        htpasswd -b -c /etc/htpasswd.d/htpasswd.${user} $user $pass
    fi

    #chmod 750 /home/${user}

}

function PostInit
{
    echo "htpasswd has been setup."
    echo ""
    echo "You may now login with the following info: ${user}:${pass}"
    echo "     /etc/htpasswd.d/htpasswd.${user}"
    echo ""
}

Preinit
Prepare
Start
Addusr
PostInit
