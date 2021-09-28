#!/bin/bash

# govc Bash completion script
# place in etc/bash_completion.d/ or source on command line with "."

_joviandss_cli_complete()
{
    local cur prev subcmd options
    prev=${COMP_WORDS[*]}
    sub="${COMP_WORDS[@]::${#COMP_WORDS[@]}-1}"
    cur=${COMP_WORDS[COMP_CWORD]}
    subcmd=${COMP_WORDS[1]}
    COMPREPLY=()

    #echo prev $prev
    #echo cur $cur
    #echo subcmd $subcmd

    if [[ ${cur} == "--" ]] ; then
        #echo $COMP_WORDS 
        COMPREPLY=( $(${prev}help | iconv -t ASCII | awk -F '[,]' '/--/{print $2}' | awk '{print $1}' | sed -r 's/[-,]+//g') ) 
        #COMPREPLY=( $(compgen -W $CMD) )

        return 0

    elif [[ ${cur} == "-" ]] ; then
        COMPREPLY=( $(${prev}h | iconv -t ASCII | awk '/^  -/{print $1}' | sed -r 's/[-,]+//g') )

        return 0
    
    elif [[ ${cur} == "--"* ]] ; then
        options=( $(${sub} --help | iconv -t ASCII | awk -F '[,]' '/--/{print $2}' | awk '{print $1}' | sed -r 's/[-,]+//g' | tr -s '\n' ' ') ) 
        echo $options
        return 0
        #COMPREPLY=( $(compgen -W "$options" -- ${cur}) )

        return 0


    #if [[ ${prev} == "jcli" ]] ; then # show subcommands, no options
    #        COMPREPLY=( $(compgen -W "$(jcli -h | grep -v Usage | tr -s '\n' ' ')" -- ${cur}) )
    #        return 0

    #elif [[ ${cur} == "-"* ]] ; then
    #        : # drop out and show options

    #elif [[ ${subcmd} == "ls" ]] ; then # not completing an option, try for appropriate values
    #        if [[ ${prev} == "-t" ]] ; then
    #                COMPREPLY=( $(compgen -W "$(govc ls -l "/**" | awk '{print $2}' | \
    #                        sort -u | tr -d '()' | tr '\n' ' '  )" -- ${cur}) )
    #        else
    #                COMPREPLY=( $(compgen -W "$(govc ls "${cur:-/*}*" | tr -s '\n' ' ' )" -- ${cur}) )
    #        fi

    #elif [[ ${subcmd} == "vm."* || ${prev} == "-vm" ]] ; then
    #        COMPREPLY=( $(compgen -W "$(govc ls -t VirtualMachine -l "${cur}*" | \
    #                awk '{print $1}' | tr -s '\n' ' ' )" -- ${cur}) )
    #fi

    ## did not hit any specifcs so show all options from help
    #if [[ -z ${COMPREPLY} ]]; then
    #        COMPREPLY=( $(compgen -W "-h $(govc ${subcmd} -h | awk '{print $1}' | \
    #                grep "^-" | sed -e 's/=.*//g' | tr -s '\n' ' ' )" -- ${cur}) )
    fi

    return 0
}
complete -F _joviandss_cli_complete jcli
