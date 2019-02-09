#!/bin/sh

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

event_entry() {
    event_start_unix=$(date -d"$1" +"%s")
    event_end_unix=$(date -d"$2" +"%s")
    event_name=$3
    start_ics=$(TZ=UTC date -d"@$event_start_unix" +"$ICS_TIME_FMT")
    end_ics=$(TZ=UTC date -d"@$event_end_unix" +"$ICS_TIME_FMT")
    printf "%d\t%s\t%s\t0\t%s\n" "0" "$start_ics" "$end_ics" "$event_name"
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
[ -z "$ISV_DAY_FMT" ] && ISV_DAY_FMT="%A, %B %d"
[ -z "$ISV_TIME_FMT" ] && ISV_TIME_FMT="%H%M"
[ -z "$ISV_FREE_STR" ] && ISV_FREE_STR="Free time"
[ -z "$ISV_COMPL_START" ] && ISV_COMPL_START="8:00"
[ -z "$ISV_COMPL_END" ] && ISV_COMPL_END="17:00"
[ -z "$ISV_COMPL_MIN" ] && ISV_COMPL_MIN="60"

WIDTH=60

NRMCOL='\033[0m'
DAYCOL='\033[0;1m'
WEKCOL='\033[1;3m'

ICS_TIME_FMT="%Y%m%dT%H%M%SZ"

CALS_FILE="$CFG_DIR/calendars"
ENTRIES="$CCH_DIR/entries"

USAGE="usage: isv <command> [<args>]

commands:
    sync       s  -- fetch and parse calendars listed in
                     $CALS_FILE
    list    ls l  -- display events from calendars"

sync_cmd() {
    [ ! -r "$CALS_FILE" ] && die 'no file with calendars at %s' "$CALS_FILE"

    mkdir -p "$CCH_DIR"

    rm_comments "$CALS_FILE" > "$RNT_DIR/cals"

    # fetch ics files
    cal_num=1
    while read -r url tags; do
        printf '%s -o %s/%s ' "$url" "$RNT_DIR" "$cal_num"
        cal_num=$((cal_num + 1))
    done < "$RNT_DIR/cals" > "$RNT_DIR/urls"
    curl -fs $(cat "$RNT_DIR/urls")
    [ "$?" -ne 0 ] && die "fetch failed"

    # parse events from ics files
    AWK_PARSE='BEGIN { fullday=0; FS=":"; OFS="\t" }
    $1 == "DTSTART" { start=$2 }
    $1 == "DTSTART;VALUE=DATE" { start=$2; fullday=1 }
    $1 ~ "DTEND*" { end=$2 }
    $1 == "LOCATION" { loc=$(NF) }
    $1 == "SUMMARY" { rs="true"; summary=$2 }
    NF == 1 && rs { summary=summary substr($1,2) } # read summary
    $1 != "SUMMARY" && NF >= 2 { rs="" } # colon -> end read summary
    $1 == "END" { print t,cn,start,end,fullday,summary " " loc; fullday=0 }'
    cal_num=1
    while read -r url tags; do
        entry=$(awk -v"t=$tags" -v"cn=$cal_num" "$AWK_PARSE" \
            "$RNT_DIR/$cal_num" | tr -d "$(printf '\r')\\" 2>/dev/null)
            [ -n "$(echo "$entry" | cut -f3)" ] && echo "$entry"
        cal_num=$((cal_num + 1))
    done < "$RNT_DIR/cals" | sort -k2 | uniq > "$ENTRIES"
}

calcol() {
    FG_START=31;COLCOUNT=7
    cal_num=$1
    cat=$((cal_num/COLCOUNT))
    col=$((cal_num%COLCOUNT))
    bold=$(((cat+1)%2))
    background=$((cat/2))
    code="$((FG_START+10*background+col))"
    [ "$cat" -eq "0" ] && code=$((code-1))
    printf "\033[$bold;${code}m"
}

list_disp_week() {
    week_number=$(date -d "$1" +"$ISV_WEEK_FMT")
    printf "\\n$WEKCOL%s$NRMCOL\\n" "$week_number"
}
list_disp_day() {
    daystr="$(date -d "$1" +"$ISV_DAY_FMT")"
    if [ "$(date -d "$1" +"%Y%m%d")" = "$(date +"%Y%m%d")" ]; then
        daystr="[ $daystr ]"
    fi
    printf "$DAYCOL%s$NRMCOL\\n" "$daystr"
}
list_disp_event() {
    if [ "$fullday" -eq "1" ]; then
        timestr="•"
    else
        start_time=$(date_ics_fmt "$start" "$ISV_TIME_FMT")
        end_time=$(date_ics_fmt "$end" "$ISV_TIME_FMT")
        timestr=$(printf '[%s-%s]' "$start_time" "$end_time")
    fi
    marglen=${#timestr}
    margin="$(printf "%${marglen}s")"
    col=$(calcol $cal_num)
    summary="$(echo $summary |\
               fmt -sw $((WIDTH-marglen)) |\
               sed "2,\$s/^/$margin /")"
    printf "$col%s$NRMCOL %s\n" "$timestr" "$summary"
}
list_cmd() {
    sync=false
    complement=false
    freetime=false
    weekdays=2
    days=
    OPTIND=1
    while getopts scfd:n:N: flag; do
        case "$flag" in
            s) sync=true;;
            c) complement=true;;
            f) complement=true; freetime=true;;
            d) day_in=$OPTARG;;
            n) weekdays=$OPTARG;;
            N) days=$OPTARG;;
            [?]) die "invalid flag -- $OPTARG"
        esac
    done
    shift $((OPTIND-1))
    [ "$weekdays" -gt 0 ] 2>/dev/null || die "invalid day count -- $weekdays"
    [ "$sync" = "true" ] && sync_cmd
    [ -r "$ENTRIES" ] || die "no cache, use sync command"
    day=$(date -d "$day_in" +"%F")
    [ -z "$day" ] && die 'invalid day -- %s' "$day_in"
    tags="${@:-default}"

    # skip weekends if N flag not used
    if [ -z $days ]; then
        dow=$(date -d "$day" +"%u")
        days=$((weekdays+(dow+(weekdays-1)%5+1)/7*2-dow/7+(weekdays-1)/5*2))
    elif ! [ "$days" -gt 0 ] 2>/dev/null; then
        die "invalid day count -- $days"
    fi
    # determine interval
    int_start=$(date -d "$day" +"%s");
    int_end=$(date -d "$day +$days days" +"%s");

    # filter out tags
    for tag in $tags; do
        AWK_FILTER='BEGIN { FS="\t" }
        $1 ~ /( |^)'$tag'( |$)/ { print }'
        awk "$AWK_FILTER" "$ENTRIES"
    done | cut -f2- | sort -k2 > "$RNT_DIR/entries"

    if [ "$complement" = "true" ]; then
        # add dummy events outside interval
        day_curr="$day"
        for i in $(seq $days); do
            if [ "$(date -d"$day_curr" +"%u")" -gt "5" ]; then
                # fill weekends
                event_entry "$day_curr" "$day_curr +1day" "dummy"
            else
                # fill morning and evening on weekdays
                event_entry "$day_curr" "$day_curr $ISV_COMPL_START" "dummy"
                event_entry "$day_curr $ISV_COMPL_END" "$day_curr +1day" "dummy"
            fi
            day_curr="$(date -d"$day_curr +1day" +"%F")"
        done > "$RNT_DIR/entries_dummies"
        sort -k2 "$RNT_DIR/entries_dummies" "$RNT_DIR/entries" \
            > "$RNT_DIR/entries_all"

        # find gaps in schedule
        busy_end=$(date -d"$day" +"%s")
        while read -r cal_num start end fullday summary; do
            [ "$fullday" -eq "1" ] && continue
            event_start=$(date_ics_fmt "$start" "%s")
            event_end=$(date_ics_fmt "$end" "%s")
            [ "$int_end" -lt "$event_start" ] && break
            if [ "$event_start" -ge "$((busy_end+ISV_COMPL_MIN*60))" ]; then
                event_entry "@$busy_end" "@$event_start" "$ISV_FREE_STR"
            fi
            [ "$event_end" -gt "$busy_end" ] && busy_end="$event_end"
        done < "$RNT_DIR/entries_all" > "$RNT_DIR/entries_compl"

        if [ "$freetime" = "true" ]; then
            cat "$RNT_DIR/entries_compl" >> "$RNT_DIR/entries"
            sort -k2 -o "$RNT_DIR/entries" "$RNT_DIR/entries"
        else
            cp "$RNT_DIR/entries_compl" "$RNT_DIR/entries"
        fi
    fi
    
    # display events
    day_end=0
    week_end=0
    while read -r cal_num start end fullday summary; do
        summary=$(echo $summary | tr -s " ")
        [ -z "$start" ] && continue;
        event_start=$(date_ics_fmt "$start" "%s")
        [ "$int_end" -lt "$event_start" ] && break
        if [ "$int_start" -lt "$event_start" ]; then
            day=$(date -d "@$event_start" +"%F")
            if [ "$day_end" -lt "$event_start" ]; then
                if [ "$week_end" -le "$event_start" ]; then
                    list_disp_week "@$event_start"
                    days_rem="$((8-$(date -d "@$event_start" +"%u")))"
                    week_end=$(date -d "$day +${days_rem}days" +"%s")
                fi
                day_end=$(date -d "$day +1day" +"%s")
                list_disp_day "$day"
            fi
            list_disp_event
        fi
    done < "$RNT_DIR/entries" | tail -n +2
}

mkdir -p "$RNT_DIR"
 
command=$1
[ -z "$command" ] && list_cmd && exit 0
shift

case "$command" in
    s|sync) sync_cmd "$@";;
    l|ls|list) list_cmd "$@";;
    *) die 'invalid command -- %s\n\n%s' "$command" "$USAGE";;
esac

rm -rf "$RNT_DIR"
