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
    touch "$ENTRIES"

    AWK_PARSE='BEGIN { FS=":"; OFS="\t" }
    $1 == "DTSTART" { start=$2 }
    $1 == "DTEND" { end=$2 }
    $1 == "SUMMARY" { rs=true; summary=$2 }
    NF == 1 && rs == true { summary=summary substr($1,2) } # read summary
    NF == 2 { rs=false } # colon -> end read summary
    $1 == "END" { print t,cn,start,end,summary }'

    cal_num=0
    while read -r url tags; do
        curl -s "$url" | tr -d '\r' > "$RNT_DIR/schedule.ics"
        awk -v"t=$tags" -v"cn=$cal_num" "$AWK_PARSE" "$RNT_DIR/schedule.ics" |\
            tr -d '\' 2>/dev/null
        cal_num=$((cal_num + 1))
    done < "$RNT_DIR/cals" > "$RNT_DIR/entries_new"
    cat "$ENTRIES" "$RNT_DIR/entries_new" | sort -k2 | uniq > $ENTRIES

    rm -rf "$RNT_DIR"
}

list_cmd() {
    week_count=1
    full_week=false
    day=
    OPTIND=1
    while getopts d:fn: flag; do
        case "$flag" in
            d) day=$OPTARG;;
            f) full_week=true;;
            n) week_count=$OPTARG;;
            [?]) die "invalid flag -- $OPTARG"
        esac
    done
    shift $((OPTIND-1))
    tags="$*"
    [ "$week_count" -gt 0 ] 2>/dev/null || \
        die "invalid week count -- $week_count"
    [ -r "$ENTRIES" ] || die "no cache, use sync command"
    if [ -n "$day" ]; then
        int_start=$(date -d "$day" +"%s");
        int_end=$(date -d "$day +1 day" +"%s");
    else
        if [ "$full_week" = "true" ];
        then int_start=$(date -d "monday -1 week" +"%s")
        else int_start=$(date +"%s")
        fi
        int_end=$(date -d "monday $((week_count - 1)) week" +"%s")
    fi

    mkdir -p "$RNT_DIR"

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
    
    day_end=0
    week_end=0
    while read -r cal_num start end summary; do
        start_unix=$(date_ics_fmt "$start" "%s")
        [ "$int_end" -lt "$start_unix" ] && break
        if [ "$int_start" -lt "$start_unix" ]; then
            day=$(date -d "@$start_unix" +"%F")
            if [ "$week_end" -le "$start_unix" ]; then
                day_num=$(date -d "@$start_unix" +"%u")
                days_rem=$((8 - day_num))
                week_end=$(date -d "$day +${days_rem}days" +"%s")
                week=$(date -d "@$start_unix" +"$ISV_WEEK_FMT")
                printf '\n'$WEEK_COL'%s'$NORMAL_COL'\n' "$week"
            fi
            if [ "$day_end" -lt "$start_unix" ]; then
                day_end=$(date -d "$day +1day" +"%s")
                printf ''$DAY_COL'%s'$NORMAL_COL'\n' \
                    "$(date -d "$day" +"$ISV_DAY_FMT")"
            fi
            start_time=$(date_ics_fmt "$start" "$ISV_TIME_FMT")
            end_time=$(date_ics_fmt "$end" "$ISV_TIME_FMT")
            if [ "$cal_num" -le 6 ];
            then col_num="$((30 + cal_num))"
            else col_num="$((34 + cal_num))"
            fi
            color='\033[1;'${col_num}'m'
            printf "$color[%s-%s]$NORMAL_COL $SUM_COL%s%s$NORMAL_COL" \
                        "$start_time" "$end_time" "$summary" |\
                fmt -sw 60 |\
                sed '2,$s/^/            /g'
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
