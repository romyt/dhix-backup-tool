#!/bin/bash
set -e
#########################################################
# postgres backup script v1.2
# author: Romain Tohouri
# licence: public domain 
#
# using some ideas from Bob Jolliffe and
# http://wiki.postgresql.org/wiki/Automated_Backup_on_Linux
#########################################################
#java -version

# Define paths and variables
mkdir -p /var/lib/postgresql/backups
BACKUP_DIR=/var/lib/postgresql/backups
#REMOTE="backup@sigsante.synology.me:8000:./dhis"
#USER=$2
#DBNAME=$1
LOG_LEVEL=$1
USER=$POSTGRES_USER
BACKUP_SOURCE_DB_HOST_NAME=$PG_MASTER_SERVICE
BACKUP_TEST_DB_HOST_NAME=$PG_REPLICA_SERVICE
now="$(date +'%d_%m_%Y_%H')"

DAY_OF_WEEK_TO_KEEP=$DAY_OF_WEEK_TO_KEEP #1-7 (Monday-Sunday) # Keep Sunday's backup
DAYS_TO_KEEP=$DAYS_TO_KEEP # keep last 7 days of backup
WEEKS_TO_KEEP=$WEEKS_TO_KEEP # keep last 6 weekly backup
MONTHS_TO_KEEP=$MONTHS_TO_KEEP # Keep last 12 monthly backups
HOURS_TO_KEEP=$HOURS_TO_KEEP # keep last 24 hourly backups
DAILY_BACKUP_TIME=$DAILY_BACKUP_TIME
DAY_OF_MONTH=$(date +'%d')
dt=$(date '+%d/%m/%Y %H:%M:%S');
EXPIRED_HOURS=`expr $((($HOURS_TO_KEEP) + 1))`
EXPIRED_DAYS=`expr $((($DAYS_TO_KEEP) + 1))`
EXPIRED_WEEKS=`expr $((($WEEKS_TO_KEEP * 7) + 1))`
EXPIRED_MONTHS=`expr $((($MONTHS_TO_KEEP * 30) + 5))`
#EXCLUDED="-T aggregated* -T analytics* -T completeness*"
EXCLUDED="-T analytics* -T completeness*"
TEMP_DB_NAME="test_db"  # Name for temporary dat abase to restore to
POSTGRES_USER=$POSTGRES_USER  # Adjust username if needed

# Function to calculate expiration days based on retention period
expiration_days() {
  case "$1" in
    "hourly") echo $EXPIRED_HOURS ;;
    "daily") echo $EXPIRED_DAYS ;;
    "weekly") echo $EXPIRED_WEEKS ;;
    "monthly") echo $EXPIRED_MONTHS ;;
  esac
}

#=======================================================
# Function to backup globals only #
#=======================================================
function globals_only_backups()
{
    pg_dumpall --globals-only -p 5432 -h $BACKUP_SOURCE_DB_HOST_NAME -U postgres | gzip > $BACKUP_DIR/postgres_globals.sql.gz
}


#=======================================================
# Function to compare schema and data of two databases #
#=======================================================
compare_databases() {
  db_name="$1" #$db_name name of the original database
  TEMP_DB_NAME="$2" #$TEMP_DB_NAME tomporary database created using the backup file
  echo "database name= $BACKUP_SOURCE_DB_HOST_NAME ($db_name) and test database= $BACKUP_TEST_DB_HOST_NAME ($TEMP_DB_NAME)"
  # Compare schema from master DB to replica test DB using pg_dump -s, excluding analytics table and table owner backing up in plain text
  # schema_diff=$(pg_dump -s -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -O -Fp $db_name $EXCLUDED| diff -U0 -  <(pg_dump -s -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -O -Fp $TEMP_DB_NAME $EXCLUDED))
  schema_diff=$(pg_dump -s -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -O -Fp $db_name $EXCLUDED| diff -U0 -  <(pg_dump -s -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER -O -Fp $TEMP_DB_NAME $EXCLUDED))
  
  echo "differences between the 2 DB schema_diff=$schema_diff"
  if [[ -z "$schema_diff" ]]; then
    echo "Good! Schema of $BACKUP_SOURCE_DB_HOST_NAME ($db_name) and $BACKUP_TEST_DB_HOST_NAME ($TEMP_DB_NAME) are identical."
    if [[ $LOG_LEVEL == "all" ]]; then
      # Add logic to send notification about successful/failed tests (modify as needed)
      MESSAGE="Good! Schema of $BACKUP_SOURCE_DB_HOST_NAME ($db_name) and $BACKUP_TEST_DB_HOST_NAME ($TEMP_DB_NAME) are identical."
      wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK  &>/dev/null || true
    fi
  else
    echo "WARNING: Schema differences found between $BACKUP_SOURCE_DB_HOST_NAME ($db_name) and $BACKUP_TEST_DB_HOST_NAME ($TEMP_DB_NAME):"
    echo "$schema_diff"
    MESSAGE="WARNING! Schema differences found between $BACKUP_SOURCE_DB_HOST_NAME($db_name) and $BACKUP_TEST_DB_HOST_NAME($TEMP_DB_NAME)"
    wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK  &>/dev/null || true
  fi

  # Sample data comparison using count(*) on random tables
  #tables=$(psql -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -d $db_name -q -t -c "SELECT table_name FROM information_schema.tables WHERE table_schema NOT IN ('information_schema', 'pg_catalog');")
  tables=$TABLES_TO_CHECK  # Taking the list of table to check from a variable defined in the yaml config 
  for table in $tables; do
    # Get row count from both databases
    count1=$(psql -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -d $db_name -q -t -c "SELECT count(*) FROM $table;")
    count2=$(psql -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER -d $TEMP_DB_NAME -q -t -c "SELECT count(*) FROM $table;")
    if [[ "$count1" != "$count2" ]]; then
      echo "WARNING! backup integrity test error, Row count mismatch for table $table in $BACKUP_SOURCE_DB_HOST_NAME.$db_name ($count1) and $BACKUP_TEST_DB_HOST_NAME.$TEMP_DB_NAME ($count2)"
      MESSAGE="WARNING backup integrity test error Row count mismatch for table $table in $BACKUP_SOURCE_DB_HOST_NAME.$db_name($count1) and $BACKUP_TEST_DB_HOST_NAME.$TEMP_DB_NAME($count2)"
      wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK &>/dev/null || true
    else
      echo "$dt - backup integrity test: Row count match for table $table in $BACKUP_SOURCE_DB_HOST_NAME - $db_name ($count1) and $BACKUP_TEST_DB_HOST_NAME - $TEMP_DB_NAME ($count2)."
     
      if [[ $LOG_LEVEL == "all" ]]; then
        # Add logic to send notification about successful/failed tests (modify as needed)
        MESSAGE="Good! $table Row count match for $BACKUP_SOURCE_DB_HOST_NAME.$db_name($count1) and $BACKUP_TEST_DB_HOST_NAME.$TEMP_DB_NAME($count2)"
        wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\"}" \
                $WEBHOOK &>/dev/null || true
      fi
    fi
  done
  # Clean up temporary database
  echo "Dropping temporary database: $TEMP_DB_NAME"
  #dropdb -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER $TEMP_DB_NAME
  dropdb -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER $TEMP_DB_NAME &>/dev/null || true
}

#=======================================================
# Test a specific backup                               #
#=======================================================
test_backup() {
  backup_file="$1"
  db_name="$2"
  echo "$dt Backup file testing started - File $1 against database $BACKUP_TEST_DB_HOST_NAME ($2)"
  # Extract filename without path
  filename=$(basename "$backup_file")

  # Check if filename extension is .sql.gz
  if [[ ! "$filename" =~ \.sql\.gz$ ]]; then
    echo "Skipping file $filename: not a .sql.gz file."
    return
  fi
  
  # Drop and recreate temporary database
  echo "Dropping and recreating temporary database: $TEMP_DB_NAME"
  dropdb -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER $TEMP_DB_NAME &>/dev/null || true
  createdb -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER $TEMP_DB_NAME

  # Restore backup to temporary database
  echo "Restoring backup $filename to temporary database: $BACKUP_TEST_DB_HOST_NAME ($TEMP_DB_NAME)"

  # Uncompress the backup file and pipe the output to psql for restoration
  gunzip -c "$backup_file" | psql -h $BACKUP_TEST_DB_HOST_NAME -U $POSTGRES_USER -d $TEMP_DB_NAME

  if [[ $? -eq 0 ]]; then
    echo "Backup $filename restored successfully."
    if [ "$LOG_LEVEL" = "all" ]; then
      MESSAGE="Backup integrity test, Backup $filename restored successfully."
      wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK  &>/dev/null || true
    fi
    # Compare schema and data
    compare_databases $db_name $TEMP_DB_NAME
   

  else
    echo "ERROR: Failed to restore backup $filename!"
    MESSAGE="ERROR! Failed to restore backup $filename."
    wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK  &>/dev/null || true
  fi
}


#==========================================================
# Backup function                                         #
#==========================================================
function perform_backups()
{
    SUFFIX=$1

    DBLIST=`psql -p 5432 -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -d postgres -q -t -c \
    "select datname from pg_database where not datistemplate" | grep '\S' | awk '{$1=$1};1'`

    echo "$dt - list of databases to backup: $DBLIST"

    for DBNAME in $DBLIST
    do
        if ! [ "$DBNAME" = "postgres" ] && ! [ "$DBNAME" = "$TEMP_DB_NAME" ]; then
            FINAL_BACKUP_DIR=$BACKUP_DIR/$DBNAME/backup"`date +\%Y-\%m-\%d`-$SUFFIX/"
            if ! mkdir -p $FINAL_BACKUP_DIR; then
                echo "$dt - Cannot create backup directory in $FINAL_BACKUP_DIR. Go and fix it!"
                exit 1;
            fi;
        fi
    done

  for DBNAME in $DBLIST
  do
        FINAL_BACKUP_DIR=$BACKUP_DIR/$DBNAME/backup"`date +\%Y-\%m-\%d`-$SUFFIX/"
        filename=$DBNAME"_"$SUFFIX"_backup_"$now".sql.gz"
        filepath=$FINAL_BACKUP_DIR$filename
        if ! [ "$DBNAME" = "postgres" ] && ! [ -f "$filepath" ]; then

            echo "$dt - backing up database: $DBNAME using filename: $filename";
            
            if ! pg_dump -h $BACKUP_SOURCE_DB_HOST_NAME -U $USER -O -Fp $DBNAME $EXCLUDED | gzip > $FINAL_BACKUP_DIR"$filename".in_progress; then
                echo "$dt - [!!ERROR!!] Failed to produce compressed backup of database $DBNAME"
                MESSAGE="$dt - [!!ERROR!!] Failed to produce compressed backup of database $DBNAME"
                
                #curl -X POST -H 'Content-type: application/json' --data '{"text":"$MESSAGE"}' $WEBHOOK
                wget --header='Content-Type:application/json' \
                --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                $WEBHOOK  &>/dev/null || true
            else
                echo "$dt - Starting DB backup of database $DBNAME into file: $FINAL_BACKUP_DIR";
                echo "$dt - Running: pg_dump -h $BACKUP_SOURCE_DB_HOST_NAME -U $USER -O -Fp $DBNAME $EXCLUDED -f $FINAL_BACKUP_DIR"$filename".in_progres"

                mv $FINAL_BACKUP_DIR"$filename".in_progress $FINAL_BACKUP_DIR"$filename"

                filesize=`wc -c $FINAL_BACKUP_DIR$filename`
                echo "$dt - DB backup completed for database $DBNAME into file: $filename";
                if [ "$LOG_LEVEL" = "all" ]; then
                    MESSAGE="$dt DB backup completed for database $DBNAME into $filename The size $filesize(ko)"
                    wget --header='Content-Type:application/json' \
                    --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":raised_hands:\"}" \
                    $WEBHOOK  &>/dev/null || true
                fi
                # Test the backup before renaming it and append SUCCESS to the name
                test_backup $filepath $DBNAME
            fi
        fi
  done

}

#=====================================================
# Cleanup function with improved error handling      #
#=====================================================
cleanup() {

  prefix="$1"
  exp_days=$(expiration_days "$prefix")
  echo "Cleaning up folder with prefix $prefix and expiration hours/days $exp_days"

  DBLIST=$(psql -p 5432 -h $BACKUP_SOURCE_DB_HOST_NAME -U $POSTGRES_USER -d postgres -q -t -c \
        "select datname from pg_database where not datistemplate" | grep '\S' | awk '{print $1}')

  for DBNAME in $DBLIST; do
    if [[ "$DBNAME" != "postgres" ]]; then
      dir_to_clean="$BACKUP_DIR/$DBNAME"

      # Find files older than `exp_days` days and delete them
      if ! find "$dir_to_clean" -type f -mtime +"$exp_days" -name "*$prefix" -delete; then
        echo "Failed to delete expired $prefix backups in $dir_to_clean"
        OUTPUT= "$(find $dir_to_clean -type f -mtime +$exp_days -name *$prefix -delete;)"
        MESSAGE="$dt [!!ERROR!!] Failed to delete expired backups $OUTPUT"
        echo "$dt - [!!ERROR!!] Failed to delete expired backups output: $OUTPUT"
        wget --header='Content-Type:application/json' \
        --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":scream:\"}" \
                  $WEBHOOK  &>/dev/null || true
      fi
      # Find empty directories and delete them
      find "$dir_to_clean" -type d -empty -delete
    fi
  done
  echo "Old backup files deleted for prefix: $prefix"
  if [ "$LOG_LEVEL" = "all" ]; then
    MESSAGE="Old backup files deleted for prefix $prefix"
    #curl -X POST -H 'Content-type: application/json' --data '{"text":"$MESSAGE"}' $WEBHOOK
    wget --header='Content-Type:application/json' \
    --post-data="{\"channel\": \"$CHANNEL\", \"username\": \"StandupBot\", \"text\": \"$MESSAGE\", \"icon_emoji\": \":raised_hands:\"}" \
    $WEBHOOK  &>/dev/null || true
  fi
}

#======================
# Main execution flow #
#======================
current_day_of_month=$(date +'%d')
current_time=$(date +'%H')

# Check for monthly backups
if [[ $current_day_of_month -eq 1 ]] && [[ $DAILY_BACKUP_TIME == $current_time ]]; then
  globals_only_backups
  perform_backups "monthly"
  cleanup "monthly"

  exit 0
fi

# Check for weekly backups
day_of_week=$(date +'%u')  # 1-7 (Monday-Sunday)
if [[ $DAY_OF_WEEK_TO_KEEP -eq $day_of_week ]] && [[ $DAILY_BACKUP_TIME == $current_time ]]; then
  perform_backups "weekly"
  cleanup "weekly"

  exit 0
fi

# Check for daily backups
if [[ $DAILY_BACKUP_TIME == $current_time ]] && [[ $day_of_week -ne 7 ]]; then  # Corrected check for non-Sunday daily backups
  perform_backups "daily"
  cleanup "daily"

  exit 0
fi

# Check for hourly backups
if [[ $DAILY_BACKUP_TIME != $current_time ]]; then # Execute backups everytime the program is run except at daily backup time
  perform_backups "hourly"
  cleanup "hourly"

  exit 0
fi