#!/bin/bash

# Script to convert FLAC files to MP3 using FFmpeg
#  Dev/test: https://github.com/TheCaptain989/lidarr-flac2mp3
#  Prod: https://github.com/linuxserver/docker-mods/tree/lidarr-flac2mp3
# Resultant MP3s are fully tagged and retain same permissions as original file

# Dependencies:
#  ffmpeg
#  awk
#  curl
#  jq
#  stat
#  nice
#  basename
#  printenv
#  chmod

# Exit codes:
#  0 - success; or test
#  1 - no audio file specified on command line
#  2 - ffmpeg not found
#  3 - invalid command line arguments
#  5 - specified audio file not found
#  7 - unknown eventtype environment variable
# 10 - awk script generated an error
# 20 - general error

### Variables
export flac2mp3_script=$(basename "$0")
export flac2mp3_pid=$$
export flac2mp3_config=/config/config.xml
export flac2mp3_log=/config/logs/flac2mp3.txt
export flac2mp3_maxlogsize=1024000
export flac2mp3_maxlog=4
export flac2mp3_debug=0
export flac2mp3_type=$(printenv | sed -n 's/_eventtype *=.*$//p')

# Usage function
function usage {
  usage="
$flac2mp3_script
Audio conversion script designed for use with Lidarr

Source: https://github.com/TheCaptain989/lidarr-flac2mp3

Usage:
  $0 [OPTIONS] [-b <bitrate> | -v <quality> | -a \"<options>\" -e <extension>]
  $0 [OPTIONS] {-f|--file} <audio_file>

Options:
  -d, --debug [<level>]          enable debug logging
                                 Level is optional, default of 1 (low)
  -b, --bitrate <bitrate>        set output quality in constant bits per second [default: 320k]
                                 Ex: 160k, 240k, 300000
  -v, --quality <quality>        set variable bitrate; quality between 0-9
                                 0 is highest quality, 9 is lowest
                                 See https://trac.ffmpeg.org/wiki/Encode/MP3 for more details
  -a, --advanced \"<options>\"   advanced ffmpeg options enclosed in quotes
                                 Specified options replace all script defaults and are sent as
                                 entered to ffmpeg for processing.
                                 See https://ffmpeg.org/ffmpeg.html#Options for details on valid options.
                                 WARNING: You must specify an audio codec!
                                 WARNING: Invalid options could result in script failure!
                                 Requires -e option to also be specified
                                 See https://github.com/TheCaptain989/lidarr-flac2mp3 for more details
  -e, --extension <extension>    file extension for output file, with or without dot
                                 Required when -a is specified!
  -f, --file <audio_file>        if included, the script enters batch mode
                                 and converts the specified audio file.
                                 WARNING: Do not use this argument when called
                                 from Lidarr!
      --help                     display this help and exit

Examples:
  $flac2mp3_script -b 320k                # Output 320 kbit/s MP3 (non VBR; same as default behavior)
  $flac2mp3_script -v 0                   # Output variable bitrate MP3, VBR 220-260 kbit/s
  $flac2mp3_script -d -b 160k             # Enable debugging level 1 and set output a 160 kbit/s MP3
  $flac2mp3_script -a \"-vn -c:a libopus -b:a 192K\" -e .opus
                                          # Convert to Opus format, VBR 192 kbit/s, no cover art
  $flac2mp3_script -a \"-y -map 0 -c:a aac -b:a 240K -c:v copy\" -e mp4
                                          # Convert to MP4 format, using AAC 240 kbit/s audio,
                                          # cover art, overwrite file
  $flac2mp3_script --file \"/path/to/audio/a-ha/Hunting High and Low/01 Take on Me.flac\"
                                          # Batch Mmode
                                          # Output 320 kbit/s MP3
"
  echo "$usage" >&2
}

# Process arguments
while (( "$#" )); do
  case "$1" in
    -d|--debug ) # Enable debugging, with optional level
      if [ -n "$2" ] && [ ${2:0:1} != "-" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
        export flac2mp3_debug=$2
        shift 2
      else
        export flac2mp3_debug=1
        shift
      fi
      ;;
    --help ) # Display usage
      usage
      exit 0
      ;;
    -f|--file ) # Batch Mode
      if [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        # Overrides detected *_eventtype
        export flac2mp3_type="batch"
        export flac2mp3_tracks="$2"
        shift 2
      else
        echo "Error|Invalid option: $1 requires an argument." >&2
        usage
        exit 1
      fi
      ;;
    -b|--bitrate ) # Set constant bit rate
      if [ -n "$flac2mp3_vbrquality" ]; then
        echo "Error|Both -b and -v options cannot be set at the same time." >&2
        usage
        exit 3
      elif [ -n "$flac2mp3_ffmpegadv" -o -n "$flac2mp3_extension" ]; then
        echo "Error|The -a and -e options cannot be set at the same time as either -v or -b options." >&2
        usage
        exit 3
      elif [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        export flac2mp3_bitrate="$2"
        shift 2
      else
        echo "Error|Invalid option: $1 requires an argument." >&2
        usage
        exit 3
      fi
      ;;
    -v|--quality ) # Set variable quality
      if [ -n "$flac2mp3_bitrate" ]; then
        echo "Error|Both -v and -b options cannot be set at the same time." >&2
        usage
        exit 3
      elif [ -n "$flac2mp3_ffmpegadv" -o -n "$flac2mp3_extension" ]; then
        echo "Error|The -a and -e options cannot be set at the same time as either -v or -b options." >&2
        usage
        exit 3
      elif [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        export flac2mp3_vbrquality="$2"
        shift 2
      else
        echo "Error|Invalid option: $1 requires an argument." >&2
        usage
        exit 3
      fi
      ;;
    -a|--advanced ) # Set advanced options
      if [ -n "$flac2mp3_vbrquality" -o -n "$flac2mp3_bitrate" ]; then
        echo "Error|The -a and -e options cannot be set at the same time as either -v or -b options." >&2
        usage
        exit 3
      elif [ -n "$2" ]; then
        export flac2mp3_ffmpegadv="$2"
        shift 2
      else
        echo "Error|Invalid option: $1 requires an argument." >&2
        usage
        exit 3
      fi
      ;;
    -e|--extension ) # Set file extension
      if [ -n "$flac2mp3_vbrquality" -o -n "$flac2mp3_bitrate" ]; then
        echo "Error|The -a and -e options cannot be set at the same time as either -v or -b options." >&2
        usage
        exit 3
      elif [ -n "$2" ] && [ ${2:0:1} != "-" ]; then
        export flac2mp3_extension="$2"
        shift 2
      else
        echo "Error|Invalid option: $1 requires an argument." >&2
        usage
        exit 3
      fi
      # Test for dot
      [ "${flac2mp3_extension:0:1}" != "." ] && flac2mp3_extension=".${flac2mp3_extension}"
      ;;
    -*|--*=) # Unknown option
      echo "Error|Unknown option: $1" >&2
      usage
      exit 20
      ;;
    *) # Remove unknown positional parameters
      shift
      ;;
  esac
done

# Test for either -a and -e, but not both: logical XOR = non-equality
if [ "${flac2mp3_ffmpegadv:+data}" != "${flac2mp3_extension:+data}" ]; then
  echo "Error|The -a and -e options must be specified together." >&2
  usage
  exit 3
fi

# Set default bit rate
[ -z "$flac2mp3_vbrquality" -a -z "$flac2mp3_bitrate" -a -z "$flac2mp3_ffmpegadv" -a -z "$flac2mp3_extension" ] && flac2mp3_bitrate="320k"

## Mode specific variables
if [[ "${flac2mp3_type,,}" = "batch" ]]; then
  # Batch mode
  export lidarr_eventtype="Convert"
elif [[ "${flac2mp3_type,,}" = "lidarr" ]]; then
  export flac2mp3_tracks="$lidarr_addedtrackpaths"
  # Catch for other environment variable
  [ -z "$flac2mp3_tracks" ] && flac2mp3_tracks="$lidarr_trackfile_path"
else
  # Called in an unexpected way
  echo -e "Error|Unknown or missing 'lidarr_eventtype' environment variable: ${flac2mp3_type}\nNot called within Lidarr?\nTry using Batch Mode option: -f <file>"
  exit 7
fi

### Functions

# Can still go over flac2mp3_maxlog if read line is too long
#  Must include whole function in subshell for read to work!
function log {(
  while read
  do
    echo $(date +"%y-%-m-%-d %H:%M:%S.%1N")\|"[$flac2mp3_pid]$REPLY" >>"$flac2mp3_log"
    local flac2mp3_filesize=$(stat -c %s "$flac2mp3_log")
    if [ $flac2mp3_filesize -gt $flac2mp3_maxlogsize ]
    then
      for i in $(seq $((flac2mp3_maxlog-1)) -1 0); do
        [ -f "${flac2mp3_log::-4}.$i.txt" ] && mv "${flac2mp3_log::-4}."{$i,$((i+1))}".txt"
      done
      [ -f "${flac2mp3_log::-4}.txt" ] && mv "${flac2mp3_log::-4}.txt" "${flac2mp3_log::-4}.0.txt"
      touch "$flac2mp3_log"
    fi
  done
)}
# Inspired by https://stackoverflow.com/questions/893585/how-to-parse-xml-in-bash
function read_xml {
  local IFS=\>
  read -d \< flac2mp3_xml_entity flac2mp3_xml_content
}
# Initiate API Rescan request
function rescan {
  flac2mp3_message="Info|Calling Lidarr API to rescan artist"
  echo "$flac2mp3_message" | log
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Forcing rescan of artist '$lidarr_artist_id'. Calling Lidarr API 'RefreshArtist' using POST and URL '$flac2mp3_api_url/command'" | log
  flac2mp3_result=$(curl -s -H "X-Api-Key: $flac2mp3_apikey" \
    -d "{\"name\": 'RefreshArtist', \"artistId\": $lidarr_artist_id}" \
    -X POST "$flac2mp3_api_url/command")
  [ $flac2mp3_debug -ge 2 ] && echo "API returned: $flac2mp3_result" | awk '{print "Debug|"$0}' | log
  flac2mp3_jobid="$(echo $flac2mp3_result | jq -crM .id)"
  if [ "$flac2mp3_jobid" != "null" ]; then
    local flac2mp3_return=0
  else
    local flac2mp3_return=1
  fi
  return $flac2mp3_return
}
# Check result of rescan job
function check_rescan {
  local i=0
  for ((i=1; i <= 15; i++)); do
    [ $flac2mp3_debug -ge 1 ] && echo "Debug|Checking job $flac2mp3_jobid completion, try #$i. Calling Lidarr API using GET and URL '$flac2mp3_api_url/command/$flac2mp3_jobid'" | log
    flac2mp3_result=$(curl -s -H "X-Api-Key: $flac2mp3_apikey" \
      -X GET "$flac2mp3_api_url/command/$flac2mp3_jobid")
    [ $flac2mp3_debug -ge 2 ] && echo "API returned: $flac2mp3_result" | awk '{print "Debug|"$0}' | log
    if [ "$(echo $flac2mp3_result | jq -crM .status)" = "completed" ]; then
      local flac2mp3_return=0
      break
    else
      if [ "$(echo $flac2mp3_result | jq -crM .status)" = "failed" ]; then
        local flac2mp3_return=2
        break
      else
        # It may have timed out, so let's wait a second
        local flac2mp3_return=1
        [ $flac2mp3_debug -ge 1 ] && echo "Debug|Job not done.  Waiting 1 second." | log
        sleep 1
      fi
    fi
  done
  return $flac2mp3_return
}

# Check for required binaries
if [ ! -f "/usr/bin/ffmpeg" ]; then
  flac2mp3_message="Error|/usr/bin/ffmpeg is required by this script"
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
  exit 2
fi

# Log Debug state
if [ $flac2mp3_debug -ge 1 ]; then
  flac2mp3_message="Debug|Enabling debug logging level ${flac2mp3_debug}. Starting ${lidarr_eventtype^} run."
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
fi

# Log environment
[ $flac2mp3_debug -ge 2 ] && printenv | sort | sed 's/^/Debug|/' | log

# Log Batch mode
if [ "$flac2mp3_type" = "batch" ]; then
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Switching to batch mode. Input filename: ${flac2mp3_tracks}" | log
fi

# Check for config file
if [ "$flac2mp3_type" = "batch" ]; then
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Not using config file in batch mode." | log
elif [ -f "$flac2mp3_config" ]; then
  # Read Lidarr config.xml
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Reading from Lidarr config file '$flac2mp3_config'" | log
  while read_xml; do
    [[ $flac2mp3_xml_entity = "Port" ]] && flac2mp3_port=$flac2mp3_xml_content
    [[ $flac2mp3_xml_entity = "UrlBase" ]] && flac2mp3_urlbase=$flac2mp3_xml_content
    [[ $flac2mp3_xml_entity = "BindAddress" ]] && flac2mp3_bindaddress=$flac2mp3_xml_content
    [[ $flac2mp3_xml_entity = "ApiKey" ]] && flac2mp3_apikey=$flac2mp3_xml_content
  done < $flac2mp3_config

  [[ $flac2mp3_bindaddress = "*" ]] && flac2mp3_bindaddress=localhost

  # Build URL to Lidarr API
  flac2mp3_api_url="http://$flac2mp3_bindaddress:$flac2mp3_port$flac2mp3_urlbase/api/v1"

  # Check Lidarr version
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Getting Lidarr version. Calling Lidarr API using GET and URL '$flac2mp3_api_url/system/status'" | log
  flac2mp3_result=$(curl -s -H "X-Api-Key: $flac2mp3_apikey" \
    -X GET "$flac2mp3_api_url/system/status")
  flac2mp3_return=$?; [ "$flac2mp3_return" != 0 ] && {
    flac2mp3_message="Error|[$flac2mp3_return] curl or jq error when parsing: \"$flac2mp3_api_url/system/status\""
    echo "$flac2mp3_message" | log
    echo "$flac2mp3_message" >&2
  }
  [ $flac2mp3_debug -ge 2 ] && echo "API returned: $flac2mp3_result" | awk '{print "Debug|"$0}' | log
  flac2mp3_version="$(echo $flac2mp3_result | jq -crM .version)"
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Detected Lidarr version $flac2mp3_version" | log

  # Get RecycleBin
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Getting Lidarr RecycleBin. Calling Lidarr API using GET and URL '$flac2mp3_api_url/config/mediamanagement'" | log
  flac2mp3_result=$(curl -s -H "X-Api-Key: $flac2mp3_apikey" \
    -X GET "$flac2mp3_api_url/config/mediamanagement")
  flac2mp3_return=$?; [ "$flac2mp3_return" != 0 ] && {
    flac2mp3_message="Error|[$flac2mp3_return] curl error when parsing: \"$flac2mp3_api_url/v3/config/mediamanagement\""
    echo "$flac2mp3_message" | log
    echo "$flac2mp3_message" >&2
  }
  [ $flac2mp3_debug -ge 2 ] && echo "API returned: $flac2mp3_result" | awk '{print "Debug|"$0}' | log
  flac2mp3_recyclebin="$(echo $flac2mp3_result | jq -crM .recycleBin)"
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Detected Lidarr RecycleBin '$flac2mp3_recyclebin'" | log
else
  # No config file means we can't call the API.  Best effort at this point.
  flac2mp3_message="Warn|Unable to locate Lidarr config file: '$flac2mp3_config'"
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
fi

# Handle Lidarr Test event
if [[ "$lidarr_eventtype" = "Test" ]]; then
  echo "Info|Lidarr event: $lidarr_eventtype" | log
  flac2mp3_message="Info|Script was test executed successfully."
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
  exit 0
fi

# Check if source audio file exists
if [ "$flac2mp3_type" = "batch" -a ! -f "$flac2mp3_tracks" ]; then
  flac2mp3_message="Error|Input file not found: \"$flac2mp3_tracks\""
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
  exit 5
fi

# Legacy one-liner script for posterity
#find "$lidarr_artist_path" -name "*.flac" -exec bash -c 'ffmpeg -loglevel warning -i "{}" -y -acodec libmp3lame -b:a 320k "${0/.flac}.mp3" && rm "{}"' {} \;

#### BEGIN MAIN
flac2mp3_message="Info|Lidarr event: ${lidarr_eventtype}"
if [ "$flac2mp3_type" != "batch" ]; then
  flac2mp3_message+=", Artist: ${lidarr_artist_name} (${lidarr_artist_id}), Album: ${lidarr_album_title} (${lidarr_album_id})"
fi
if [ -z "$flac2mp3_ffmpegadv" ]; then
  flac2mp3_message+=", Export bitrate: ${flac2mp3_bitrate:-$flac2mp3_vbrquality}"
else
  flac2mp3_message+=", Advanced options: '${flac2mp3_ffmpegadv}', File extension: ${flac2mp3_extension}"
fi
flac2mp3_message+=", Track(s): ${flac2mp3_tracks}"
echo "${flac2mp3_message}" | log

echo "$flac2mp3_tracks" | awk -v Debug=$flac2mp3_debug \
-v Recycle="$flac2mp3_recyclebin" \
-v Bitrate="$flac2mp3_bitrate" \
-v VBR="$flac2mp3_vbrquality" \
-v FFmpegADV="$flac2mp3_ffmpegadv" \
-v EXT="$flac2mp3_extension" '
BEGIN {
  FFmpeg="/usr/bin/ffmpeg"
  FS="|"
  RS="|"
  IGNORECASE=1
  if (EXT == "") EXT=".mp3"
  if (Bitrate) {
    if (Debug >= 1) print "Debug|Using constant bitrate of "Bitrate
    BrCommand="-b:a "Bitrate
  } else if (VBR) {
    if (Debug >= 1) print "Debug|Using variable quality of "VBR
    BrCommand="-q:a "VBR
  } else if (FFmpegADV) {
    if (Debug >= 1) print "Debug|Using advanced ffmpeg options: \""FFmpegADV"\""
    if (Debug >= 1) print "Debug|Exporting with file extension "EXT
  }
}
/\.flac/ {
  # Get each FLAC file name and create a new MP3 (or other) name
  Track=$1
  sub(/\n/,"",Track)
  NewTrack=substr(Track, 1, length(Track)-5) EXT
  print "Info|Writing: "NewTrack
  # Check for advanced options
  if (FFmpegADV) FFmpegOPTS=FFmpegADV
  else FFmpegOPTS="-c:v copy -map 0 -y -acodec libmp3lame "BrCommand" -write_id3v1 1 -id3v2_version 3"
  # Convert the track
  if (Debug >= 1) print "Debug|Executing: nice "FFmpeg" -loglevel error -i \""Track"\" "FFmpegOPTS" \""NewTrack"\""
  Result=system("nice "FFmpeg" -loglevel error -i \""Track"\" "FFmpegOPTS" \""NewTrack"\" 2>&1")
  if (Result) {
    print "Error|Exit code "Result" converting \""Track"\""
  } else {
    if (Recycle == "") {
      # No Recycle Bin, so check for non-zero size new file and delete the old one
      if (Debug >= 1) print "Debug|Deleting: \""Track"\" and setting permissions on \""NewTrack"\""
      #Command="[ -s \""NewTrack"\" ] && [ -f \""Track"\" ] && chown --reference=\""Track"\" \""NewTrack"\" && chmod --reference=\""Track"\" \""NewTrack"\" && rm \""Track"\""
      Command="if [ -s \""NewTrack"\" ]; then if [ -f \""Track"\" ]; then chown --reference=\""Track"\" \""NewTrack"\"; chmod --reference=\""Track"\" \""NewTrack"\"; rm \""Track"\"; fi; fi"
      if (Debug >= 2) print "Debug|Executing: "Command
      system(Command)
    } else {
      # Recycle Bin is configured, so check if it exists, append a relative path to it from the track, check for non-zero size new file, and move the old one to the Recycle Bin
      match(Track,/^\/?[^\/]+\//)
      RecPath=substr(Track,RSTART+RLENGTH)
      sub(/[^\/]+$/,"",RecPath)
      RecPath=Recycle RecPath
      if (Debug >= 1) print "Debug|Recycling: \""Track"\" to \""RecPath"\" and setting permissions on \""NewTrack"\""
      Command="if [ ! -e \""RecPath"\" ]; then mkdir -p \""RecPath"\"; fi; if [ -s \""NewTrack"\" ]; then if [ -f \""Track"\" ]; then chown --reference=\""Track"\" \""NewTrack"\"; chmod --reference=\""Track"\" \""NewTrack"\"; mv -t \""RecPath"\" \""Track"\"; fi; fi"
      if (Debug >= 2) print "Debug|Executing: "Command
      system(Command)
    }
  }
}
' | log

#### END MAIN

# Check for awk script completion
flac2mp3_return="${PIPESTATUS[1]}"    # captures awk exit status
if [ $flac2mp3_return != "0" ]; then
  flac2mp3_message="Error|Script exited abnormally.  File permissions issue?"
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
  exit 10
fi

# Call Lidarr API to RescanArtist
if [ "$flac2mp3_type" = "batch" ]; then
  [ $flac2mp3_debug -ge 1 ] && echo "Debug|Cannot use API in batch mode." | log
elif [ -n "$flac2mp3_api_url" ]; then
  # Check for artist ID
  if [ "$lidarr_artist_id" ]; then
    # Scan the disk for the new audio tracks
    if rescan; then
      # Check that the rescan completed
      if ! check_rescan; then
        # Timeout or failure
        flac2mp3_message="Warn|Lidarr job ID $flac2mp3_jobid timed out or failed."
        echo "$flac2mp3_message" | log
        echo "$flac2mp3_message" >&2
      fi
    else
      # Error from API
      flac2mp3_message="Error|The 'RefreshArtist' API with artist $lidarr_artist_id failed."
      echo "$flac2mp3_message" | log
      echo "$flac2mp3_message" >&2
    fi
  else
    # No Artist ID means we can't call the API
    flac2mp3_message="Warn|Missing environment variable lidarr_artist_id"
    echo "$flac2mp3_message" | log
    echo "$flac2mp3_message" >&2
  fi
else
  # No URL means we can't call the API
  flac2mp3_message="Warn|Unable to determine Lidarr API URL."
  echo "$flac2mp3_message" | log
  echo "$flac2mp3_message" >&2
fi

# Cool bash feature
flac2mp3_message="Info|Completed in $(($SECONDS/60))m $(($SECONDS%60))s"
echo "$flac2mp3_message" | log
