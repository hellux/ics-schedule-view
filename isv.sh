#!/bin/env sh

warn() {
    str=$1
    [ -n "$2" ]; shift
    printf 'warning: '"$str"'\n' "$@" 1>&2
}
die() {
    str=$1
    [ -n "$2" ]; shift
    printf 'error: '"$str"'\n' "$@" 1>&2
    rm -rf "$RNT_DIR"
    exit 1
}

date_ics_fmt() {
    date_ics=$(echo "$1" | cut -c-13 | sed 's/T/ /g')
    format=$2
    date -d "TZ=\"UTC\" $date_ics" +"$format"
}
rm_comments() {
    sed 's:#.*$::g;/^\-*$/d;s/ *$//' "$1"
}

if [ -z "$XDG_CACHE_HOME" ];
then CCH_DIR="$HOME/.cache/ics-schedule-view"
else CCH_DIR="$XDG_CACHE_HOME/ics-schedule-view"
fi
if [ -z "$XDG_RUNTIME_DIR" ];
then RNT_DIR="$CCH_DIR/runtime"
else RNT_DIR="$XDG_RUNTIME_DIR/ics-schedule-view"
fi
if [ -z "$XDG_CONFIG_HOME" ];
then CFG_DIR="$HOME/.config/ics-schedule-view"
else CFG_DIR="$XDG_CONFIG_HOME/ics-schedule-view"
fi

[ -z "$ISV_WEEK_FMT" ] && ISV_WEEK_FMT="Week %V"
[ -z "$ISV_DAY_FMT" ] && ISV_DAY_FMT="%A, %B %d:"
[ -z "$ISV_TIME_FMT" ] && ISV_TIME_FMT="%H%M"

NORMAL_COL='\033[0m'
DAY_COL='\033[0;1m'
WEEK_COL='\033[1;3m'
SUM_COL="$NORMAL_COL"

CALS_FILE="$CFG_DIR/calendars"
ENTRIES="$CCH_DIR/entries"

USAGE="usage: isv <command> [<args>]

commands:
    sync       s  -- fetch and parse calendars listed in
                     $CALS_FILE
    list    ls l  -- display events from calendars"

sync_cmd() {
    [ ! -r "$CALS_FILE" ] && die 'no file with calendars at %s' "$CALS_FILE"

    mkdir -p "$RNT_DIR"
    mkdir -p "$CCH_DIR"

    rm_comments "$CALS_FILE" > "$RNT_DIR/cals"

    # fetch ics files
    cal_num=0
    curl -s $(while read -r url tags; do
        printf '%s -o %s/%s ' "$url" "$RNT_DIR" "$cal_num"
        cal_num=$((cal_num + 1))
    done < "$RNT_DIR/cals")

    # parse events from ics files
    AWK_PARSE='BEGIN { FS=":"; OFS="\t" }
    $1 == "DTSTART" { start=$2 }
    $1 == "DTEND" { end=$2 }
    $1 == "SUMMARY" { rs=true; summary=$2 }
    NF == 1 && rs == true { summary=summary substr($1,2) } # read summary
    NF == 2 { rs=false } # colon -> end read summary
    $1 == "END" { print t,cn,start,end,summary }'
    cal_num=0
    while read -r url tags; do
        awk -v"t=$tags" -v"cn=$cal_num" "$AWK_PARSE" "$RNT_DIR/$cal_num" |\
            tr -d "$(printf '\r')\\" 2>/dev/null
        cal_num=$((cal_num + 1))
    done < "$RNT_DIR/cals" | sort -k2 | uniq > "$ENTRIES"

    rm -rf "$RNT_DIR"
}

list_cmd() {
    sync=false
    weekdays=2
    days=
    OPTIND=1
    while getopts sd:fn:N: flag; do
        case "$flag" in
            s) sync=true;;
            d) day_in=$OPTARG;;
            n) weekdays=$OPTARG;;
            N) days=$OPTARG;;
            [?]) die "invalid flag -- $OPTARG"
        esac
    done
    shift $((OPTIND-1))
    [ "$weekdays" -gt 0 ] 2>/dev/null || die "invalid day count -- $weekdays"
    [ -r "$ENTRIES" ] || die "no cache, use sync command"
    day=$(date -d "$day_in" +"%F")
    [ -z "$day" ] && die 'invalid day -- %s' "$day_in"
    tags=${*:-default}

    # skip weekends if N flag not used
    if [ -z $days ]; then
        dow=$(date -d "$day" +"%u")
        days=$((weekdays + (dow+weekdays%5)/7*2-dow/7 + (weekdays-1)/5*2))
    elif ! [ "$days" -gt 0 ] 2>/dev/null; then
        die "invalid day count -- $days"
    fi
    # determine interval
    int_start=$(date -d "$day" +"%s");
    int_end=$(date -d "$day +$days days" +"%s");

    [ "$sync" = "true" ] && sync_cmd

    mkdir -p "$RNT_DIR"

    # filter out tags
    if [ -z "$tags" ]; then
        cat "$ENTRIES"
    else
        for tag in $tags; do
            AWK_FILTER='BEGIN { FS="\t" }
            $1 ~ /( |^)'$tag'( |$)/ { print }'
            awk "$AWK_FILTER" "$ENTRIES"
        done
        exit
    fi | cut -f2-5 | sort -k2 > "$RNT_DIR/entries"
    
    # display
    day_end=0
    week_end=0
    while read -r cal_num start end summary; do
        start_unix=$(date_ics_fmt "$start" "%s")
        [ "$int_end" -lt "$start_unix" ] && break
        if [ "$int_start" -lt "$start_unix" ]; then
            day=$(date -d "@$start_unix" +"%F")
            if [ "$day_end" -lt "$start_unix" ]; then
                if [ "$week_end" -le "$start_unix" ]; then
                    day_num=$(date -d "@$start_unix" +"%u")
                    days_rem=$((8 - day_num))
                    week_end=$(date -d "$day +${days_rem}days" +"%s")
                    week=$(date -d "@$start_unix" +"$ISV_WEEK_FMT")
                    printf "\\n$WEEK_COL%s$NORMAL_COL\\n" "$week"
                fi
                day_end=$(date -d "$day +1day" +"%s")
                printf "$DAY_COL%s$NORMAL_COL\\n" \
                    "$(date -d "$day" +"$ISV_DAY_FMT")"
            fi
            start_time=$(date_ics_fmt "$start" "$ISV_TIME_FMT")
            end_time=$(date_ics_fmt "$end" "$ISV_TIME_FMT")
            timestr=$(printf '[%s-%s]' "$start_time" "$end_time")
            if [ "$cal_num" -le 6 ];
            then col_num="$((30 + cal_num))"
            else col_num="$((34 + cal_num))"
            fi
            color='\033[1;'${col_num}'m'
            margin="$(for _ in $(seq ${#timestr}); do printf ' '; done)"
            printf "$color%s$NORMAL_COL $SUM_COL%s%s$NORMAL_COL" \
                        "$timestr" "$summary" |\
                fmt -sw $((70-${#margin})) |\
                sed "2,\$s/^/$margin /"
        fi
    done < "$RNT_DIR/entries" | tail -n +2

    rm -rf "$RNT_DIR"
}
 
command=$1
[ -z "$command" ] && list_cmd && exit 0
shift

case "$command" in
    s|sync) sync_cmd "$@";;
    l|ls|list) list_cmd "$@";;
    *) die 'invalid command -- %s\n\n%s' "$command" "$USAGE";;
esac
