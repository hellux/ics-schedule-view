#!/usr/bin/env sh

warn() {
    echo -e "warning: $@" 1>&2
}
die() {
    echo -e "error: $@" 1>&2
    exit 1
}

if date -v 1d > /dev/null 2>&1;
then BSD_DATE=true
else BSD_DATE=false
fi
date_ics_fmt() {
    date_ics=$(echo $1 | cut -c-13 | sed 's/T/ /g')
    format=$2
    if [ "$BSD_DATE" = "true" ]
    then date -jf "%Y%m%dT%H%M %Z" "$date_ics UTC" "+$format"
    else date -d "TZ=\"UTC\" $date_ics" +"$format"
    fi
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

mkdir -p $CFG_DIR
CALS_FILE=$CFG_DIR/calendars
ENTRIES=$CCH_DIR/entries

[ -z "$ISV_DAY_FMT" ] && ISV_DAY_FMT="%A, %B %d:"
[ -z "$ISV_TIME_FMT" ] && ISV_TIME_FMT="%H%M"
[ -z "$ISV_DAY_COL" ] && ISV_DAY_COL="\033[1m"
[ -z "$ISV_TIME_COL" ] && ISV_TIME_COL="\033[1;32m"
[ -z "$ISV_SUM_COL" ] && ISV_SUM_COL="\033[0m"

int_start=$(date -d "monday -1 week" +"%s")
int_end=$(date -d "monday 1 week" +"%s")
mkdir -p $RNT_DIR || exit 1
[ ! -r $CALS_FILE ] && die "no file with calendars found at $CALS_FILE"
curl -s $(cat $CALS_FILE) | tr -d '\r' > $RNT_DIR/schedule.ics

mkdir -p $CCH_DIR
AWK_PARSE='BEGIN { FS=":"; OFS="\t" }
$1 == "DTSTART" { start=$2 }
$1 == "DTEND" { end=$2 }
$1 == "SUMMARY" { rs=true; summary=$2 }
NF == 1 && rs == true { summary=summary substr($1,2) } # read multiline summary
NF == 2 { rs=false } # colon -> end read summary
$1 == "END" { print start,end,summary }'
awk "$AWK_PARSE" $RNT_DIR/schedule.ics |\
    tr -d '\' 2>/dev/null |\
    sort > $ENTRIES
rm -rf $RNT_DIR

day_end=0
while read start end summary; do
    start_unix=$(date_ics_fmt $start "%s")
    [ "$int_end" -lt "$start_unix" ] && break
    if [ "$int_start" -lt "$start_unix" ]; then
        if [ "$day_end" -lt "$start_unix" ]; then
            day=$(date -d "@$start_unix" +"%F")
            day_end=$(date -d "$day 23:59" +"%s")
            echo -e "\n$ISV_DAY_COL$(date -d "$day" +"$ISV_DAY_FMT")\e[0m"
        fi
        start_time=$(date_ics_fmt $start "$ISV_TIME_FMT")
        end_time=$(date_ics_fmt $end "$ISV_TIME_FMT")
        echo -e "$ISV_TIME_COL[$start_time-$end_time] $ISV_SUM_COL$summary" |\
            fmt -sw 60 |\
            sed '2,$s/^/            /g'
    fi
done < $ENTRIES | tail -n +2
